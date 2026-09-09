#ifndef SPOTTY_KEYCHAIN_SUPPORT_H
#define SPOTTY_KEYCHAIN_SUPPORT_H
#include <Security/Security.h>

// Legacy Keychain operations with UI disabled for the duration of the call.
OSStatus SpottyKeychainCopyMatching(CFDictionaryRef query, CFTypeRef *result);
OSStatus SpottyKeychainAdd(CFDictionaryRef attributes);
OSStatus SpottyKeychainUpdate(CFDictionaryRef query, CFDictionaryRef attributes);
OSStatus SpottyKeychainDelete(CFDictionaryRef query);
#endif
