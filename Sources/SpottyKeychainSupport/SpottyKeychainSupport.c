#include "SpottyKeychainSupport.h"
#include <pthread.h>
#include <os/log.h>

// File-based Keychain ignores LAContext.interactionNotAllowed. These deprecated
// APIs remain its documented UI control; confine them to this compatibility leaf.
// The flag is process-wide, so serialize every Spotty operation and restore it.
static pthread_mutex_t keychainMutex = PTHREAD_MUTEX_INITIALIZER;

enum Operation { copyMatching, add, update, deleteItem };

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus perform(enum Operation operation, CFDictionaryRef query,
                        CFDictionaryRef attributes, CFTypeRef *result) {
    pthread_mutex_lock(&keychainMutex);
    Boolean wasAllowed = false;
    OSStatus status = SecKeychainGetUserInteractionAllowed(&wasAllowed);
    if (status == errSecSuccess) {
        status = SecKeychainSetUserInteractionAllowed(false);
        if (status == errSecSuccess) {
            switch (operation) {
                case copyMatching: status = SecItemCopyMatching(query, result); break;
                case add: status = SecItemAdd(query, NULL); break;
                case update: status = SecItemUpdate(query, attributes); break;
                case deleteItem: status = SecItemDelete(query); break;
            }
            // Report the actual operation's result even if restoration fails:
            // a successfully rotated credential must not be treated as unsaved.
            OSStatus restoreStatus = SecKeychainSetUserInteractionAllowed(wasAllowed);
            if (restoreStatus != errSecSuccess) {
                restoreStatus = SecKeychainSetUserInteractionAllowed(wasAllowed);
                if (restoreStatus != errSecSuccess) {
                    os_log_error(OS_LOG_DEFAULT,
                                 "Keychain interaction restoration failed: %{public}d; UI remains disabled",
                                 (int)restoreStatus);
                }
            }
        }
    }
    pthread_mutex_unlock(&keychainMutex);
    return status;
}
#pragma clang diagnostic pop

OSStatus SpottyKeychainCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    return perform(copyMatching, query, NULL, result);
}
OSStatus SpottyKeychainAdd(CFDictionaryRef attributes) {
    return perform(add, attributes, NULL, NULL);
}
OSStatus SpottyKeychainUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    return perform(update, query, attributes, NULL);
}
OSStatus SpottyKeychainDelete(CFDictionaryRef query) {
    return perform(deleteItem, query, NULL, NULL);
}
