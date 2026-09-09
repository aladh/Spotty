#include "SpottyKeychainSupport.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sched.h>

static Boolean allowed;
static OSStatus getStatus, disableStatus, restoreStatus, operationStatus;
static int calls, sets;
static Boolean transientRestoreFailure;
static Boolean concurrentMode;
static atomic_int activeSequence;
static _Thread_local int threadSets;
OSStatus SecKeychainGetUserInteractionAllowed(Boolean *value) {
    if (concurrentMode) {
        assert(atomic_fetch_add(&activeSequence, 1) == 0);
        threadSets = 0;
        sched_yield();
    }
    *value = allowed;
    return getStatus;
}
OSStatus SecKeychainSetUserInteractionAllowed(Boolean value) {
    if (concurrentMode) {
        allowed = value;
        if (++threadSets == 2) {
            assert(allowed);
            assert(atomic_fetch_sub(&activeSequence, 1) == 1);
        }
        return errSecSuccess;
    }
    sets++;
    OSStatus status = sets == 1 ? disableStatus :
        (transientRestoreFailure && sets > 2 ? errSecSuccess : restoreStatus);
    if (status == errSecSuccess) allowed = value;
    return status;
}
static OSStatus operate(void) {
    assert(!allowed);
    calls++;
    return operationStatus;
}
OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    (void)query; (void)result; return operate();
}
OSStatus SecItemAdd(CFDictionaryRef query, CFTypeRef *result) {
    (void)query; (void)result; return operate();
}
OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    (void)query; (void)attributes; return operate();
}
OSStatus SecItemDelete(CFDictionaryRef query) { (void)query; return operate(); }
static OSStatus run(int operation) {
    switch (operation) {
        case 0: return SpottyKeychainCopyMatching(NULL, NULL);
        case 1: return SpottyKeychainAdd(NULL);
        case 2: return SpottyKeychainUpdate(NULL, NULL);
        default: return SpottyKeychainDelete(NULL);
    }
}
static void *concurrentOperations(void *unused) {
    (void)unused;
    for (int iteration = 0; iteration < 100; iteration++) {
        assert(run(iteration % 4) == errSecSuccess);
    }
    return NULL;
}
int main(void) {
    for (int operation = 0; operation < 4; operation++) {
        for (int prior = 0; prior < 2; prior++) {
            for (int failure = 0; failure < 6; failure++) {
                allowed = prior; calls = sets = 0;
                getStatus = failure == 1 ? errSecNotAvailable : errSecSuccess;
                disableStatus = failure == 2 ? errSecNotAvailable : errSecSuccess;
                transientRestoreFailure = failure == 5;
                restoreStatus = failure == 3 || failure == 5 ? errSecNotAvailable : errSecSuccess;
                operationStatus = failure == 4 ? errSecInteractionNotAllowed : errSecSuccess;
                OSStatus status = run(operation);
                if (failure == 1 || failure == 2) {
                    assert(status == errSecNotAvailable && calls == 0 && allowed == prior);
                } else {
                    assert(status == operationStatus && calls == 1 && sets == (failure == 3 || failure == 5 ? 3 : 2));
                    assert(allowed == (failure == 3 ? false : prior));
                }
            }
        }
    }
    concurrentMode = true;
    allowed = true;
    getStatus = operationStatus = errSecSuccess;
    pthread_t workers[8];
    for (int index = 0; index < 8; index++) {
        assert(pthread_create(&workers[index], NULL, concurrentOperations, NULL) == 0);
    }
    for (int index = 0; index < 8; index++) assert(pthread_join(workers[index], NULL) == 0);
    assert(atomic_load(&activeSequence) == 0 && allowed);
    return 0;
}
