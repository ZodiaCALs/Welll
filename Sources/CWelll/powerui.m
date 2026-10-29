#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <stdbool.h>
#include <string.h>

#include "CWelll.h"

/*
 * macOS 26.4 added a Charge Limit to System Settings > Battery, which System Settings
 * reaches through the private PowerUISmartChargeClient class. Its method signatures are
 * undocumented and vary between releases, so every call below goes through NSInvocation
 * using the signature the Objective-C runtime reports, and exceptions are caught. The
 * daemon only calls these functions from a separate child process, so even a crash here
 * can't take it down. The file avoids ARC-only constructs so it compiles either way.
 */

@interface NSObject (WelllPowerUIClient)
- (instancetype)initWithClientName:(NSString *)clientName;
@end

static id CPUIClient(void) {
    static id client = nil;
    static BOOL attempted = NO;
    if (attempted) {
        return client;
    }
    attempted = YES;

    @try {
        dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_LAZY | RTLD_LOCAL);
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        if (cls != Nil) {
            if ([cls instancesRespondToSelector:@selector(initWithClientName:)]) {
                client = [[cls alloc] initWithClientName:@"Welll"];
            } else {
                client = [[cls alloc] init];
            }
        }
    } @catch (NSException *exception) {
        client = nil;
    }
    return client;
}

static const char *CPUISkipQualifiers(const char *type) {
    if (type == NULL) {
        return "";
    }
    while (*type != '\0' && strchr("rnNoORVA", *type) != NULL) {
        type++;
    }
    return type;
}

static BOOL CPUISetNumber(NSInvocation *invocation, NSInteger index, const char *type, long long value) {
    switch (type[0]) {
        case 'c': { signed char v = (signed char)value; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'C': { unsigned char v = (unsigned char)value; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'B': { bool v = value != 0; [invocation setArgument:&v atIndex:index]; return YES; }
        case 's': { short v = (short)value; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'S': { unsigned short v = (unsigned short)value; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'i': { int v = (int)value; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'I': { unsigned int v = (unsigned int)value; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'l': { long v = (long)value; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'L': { unsigned long v = (unsigned long)value; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'q': { long long v = value; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'Q': { unsigned long long v = (unsigned long long)value; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'f': { float v = (float)value; [invocation setArgument:&v atIndex:index]; return YES; }
        case 'd': { double v = (double)value; [invocation setArgument:&v atIndex:index]; return YES; }
        case '@': {
            NSNumber *number = [NSNumber numberWithLongLong:value];
            [invocation setArgument:&number atIndex:index];
            [invocation retainArguments];
            return YES;
        }
        default:
            return NO;
    }
}

static BOOL CPUIReadReturn(NSInvocation *invocation, const char *type, long long *out) {
    switch (type[0]) {
        case 'v': { *out = 1; return YES; }
        case 'c': { signed char v = 0; [invocation getReturnValue:&v]; *out = v; return YES; }
        case 'C': { unsigned char v = 0; [invocation getReturnValue:&v]; *out = v; return YES; }
        case 'B': { bool v = false; [invocation getReturnValue:&v]; *out = v ? 1 : 0; return YES; }
        case 's': { short v = 0; [invocation getReturnValue:&v]; *out = v; return YES; }
        case 'S': { unsigned short v = 0; [invocation getReturnValue:&v]; *out = v; return YES; }
        case 'i': { int v = 0; [invocation getReturnValue:&v]; *out = v; return YES; }
        case 'I': { unsigned int v = 0; [invocation getReturnValue:&v]; *out = v; return YES; }
        case 'l': { long v = 0; [invocation getReturnValue:&v]; *out = v; return YES; }
        case 'L': { unsigned long v = 0; [invocation getReturnValue:&v]; *out = (long long)v; return YES; }
        case 'q': { long long v = 0; [invocation getReturnValue:&v]; *out = v; return YES; }
        case 'Q': { unsigned long long v = 0; [invocation getReturnValue:&v]; *out = (long long)v; return YES; }
        case 'f': { float v = 0; [invocation getReturnValue:&v]; *out = (long long)v; return YES; }
        case 'd': { double v = 0; [invocation getReturnValue:&v]; *out = (long long)v; return YES; }
        case '@': {
            void *raw = NULL;
            [invocation getReturnValue:&raw];
            id object = (__bridge id)raw;
            if (object != nil && [object respondsToSelector:@selector(longLongValue)]) {
                *out = [object longLongValue];
                return YES;
            }
            return NO;
        }
        default:
            return NO;
    }
}

/* Calls `name` on the PowerUI client (or its class). NSError ** parameters are filled in
 * automatically; `number` goes to the first other parameter when `passNumber` is set. */
static BOOL CPUIInvoke(NSString *name, BOOL passNumber, long long number,
                       long long *result, NSString **errorText) {
    id client = CPUIClient();
    if (client == nil) {
        if (errorText != NULL) *errorText = @"macOS's charge limit service isn't available";
        return NO;
    }

    @try {
        SEL selector = NSSelectorFromString(name);
        id target = nil;
        if ([client respondsToSelector:selector]) {
            target = client;
        } else if ([[client class] respondsToSelector:selector]) {
            target = [client class];
        } else {
            if (errorText != NULL) *errorText = [NSString stringWithFormat:@"%@ isn't available", name];
            return NO;
        }

        NSMethodSignature *signature = [target methodSignatureForSelector:selector];
        if (signature == nil) {
            if (errorText != NULL) *errorText = [NSString stringWithFormat:@"%@ has no method signature", name];
            return NO;
        }

        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setTarget:target];
        [invocation setSelector:selector];

        void *errorSlot = NULL;
        void **errorPointer = &errorSlot;
        BOOL numberPassed = NO;
        NSUInteger count = [signature numberOfArguments];
        for (NSUInteger i = 2; i < count; i++) {
            const char *type = CPUISkipQualifiers([signature getArgumentTypeAtIndex:i]);
            if (type[0] == '^' && type[1] == '@') {
                [invocation setArgument:&errorPointer atIndex:(NSInteger)i];
            } else if (passNumber && !numberPassed && CPUISetNumber(invocation, (NSInteger)i, type, number)) {
                numberPassed = YES;
            } else {
                if (errorText != NULL) *errorText = [NSString stringWithFormat:@"%@ has an unexpected signature", name];
                return NO;
            }
        }
        if (passNumber && !numberPassed) {
            if (errorText != NULL) *errorText = [NSString stringWithFormat:@"%@ doesn't take a value", name];
            return NO;
        }

        [invocation invoke];

        long long value = 0;
        BOOL understood = CPUIReadReturn(invocation, CPUISkipQualifiers([signature methodReturnType]), &value);
        if (result != NULL) *result = value;
        if (errorSlot != NULL && errorText != NULL) {
            NSError *error = (__bridge NSError *)errorSlot;
            *errorText = [NSString stringWithFormat:@"%@ (%@ %ld)",
                          [error localizedDescription], [error domain], (long)[error code]];
        }
        return understood;
    } @catch (NSException *exception) {
        if (errorText != NULL) {
            *errorText = [NSString stringWithFormat:@"%@ raised %@: %@", name, [exception name], [exception reason]];
        }
        return NO;
    }
}

static void CPUICopy(NSString *message, char *buffer, int length) {
    if (buffer == NULL || length <= 0) {
        return;
    }
    const char *utf8 = message != nil ? [message UTF8String] : NULL;
    strlcpy(buffer, utf8 != NULL ? utf8 : "", (size_t)length);
}

static int CPUIFlag(NSArray *names) {
    for (NSString *name in names) {
        long long value = 0;
        NSString *message = nil;
        if (CPUIInvoke(name, NO, 0, &value, &message)) {
            if (value == 0 && message != nil) {
                return -1; /* The call itself failed, so the answer is unknown. */
            }
            return value != 0 ? 1 : 0;
        }
    }
    return -1;
}

static int CPUICall(NSString *name, char *error, int errorLength) {
    long long result = 0;
    NSString *message = nil;
    if (!CPUIInvoke(name, NO, 0, &result, &message) || result == 0) {
        CPUICopy(message != nil ? message : [NSString stringWithFormat:@"%@ failed", name], error, errorLength);
        return 0;
    }
    return 1;
}

int CPUIAvailable(void) {
    @autoreleasepool {
        return CPUIClient() != nil ? 1 : 0;
    }
}

int CPUIIsSupported(void) {
    @autoreleasepool {
        return CPUIFlag(@[@"isMCLSupported", @"isMCLSupported:"]);
    }
}

int CPUIIsEnabled(void) {
    @autoreleasepool {
        return CPUIFlag(@[@"isMCLCurrentlyEnabled:", @"isMCLCurrentlyEnabled", @"isMCLEnabled:", @"isMCLEnabled"]);
    }
}

int CPUIGetLimit(void) {
    @autoreleasepool {
        NSArray *names = @[@"getMCLLimit:", @"getMCLLimit", @"getMCLLimitWithError:",
                           @"currentMCLLimit:", @"currentMCLLimit", @"mclLimit"];
        for (NSString *name in names) {
            long long value = 0;
            if (CPUIInvoke(name, NO, 0, &value, NULL) && value >= 50 && value <= 100) {
                return (int)value;
            }
        }
        return -1;
    }
}

int CPUISetLimit(int percent, char *error, int errorLength) {
    @autoreleasepool {
        /* Reported to crash below 80%, so such values never reach macOS. */
        if (percent < 80 || percent > 100) {
            CPUICopy(@"macOS only accepts charge limits from 80 to 100 percent", error, errorLength);
            return 0;
        }
        long long result = 0;
        NSString *message = nil;
        if (!CPUIInvoke(@"setMCLLimit:error:", YES, percent, &result, &message) || result == 0) {
            CPUICopy(message != nil ? message : @"macOS rejected the charge limit", error, errorLength);
            return 0;
        }
        return 1;
    }
}

int CPUIEnable(char *error, int errorLength) {
    @autoreleasepool {
        return CPUICall(@"enableMCL:", error, errorLength);
    }
}

int CPUIDisable(char *error, int errorLength) {
    @autoreleasepool {
        return CPUICall(@"disableMCL:", error, errorLength);
    }
}
