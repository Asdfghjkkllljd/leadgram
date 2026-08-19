#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const NSTimeInterval kDelay = 12.0;

static NSString *logPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TgSendDelay.log"];
}

static void logAppend(NSString *s) {
    NSString *line = [NSString stringWithFormat:@"%@\n", s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath()];
    if (!fh) {
        [line writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// ── Сканируем рантайм: какие классы/методы с отправкой реально есть ──
static void scanAndReport(void) {
    @autoreleasepool {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"== TgSendDelay scan %@ ==\n", [NSDate date]];

        int n = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * n);
        objc_getClassList(classes, n);

        for (int i = 0; i < n; i++) {
            NSString *cn = NSStringFromClass(classes[i]);
            BOOL hit = [cn containsString:@"ChatController"]
                    || [cn containsString:@"ChatSend"]
                    || [cn containsString:@"InputPanel"]
                    || [cn containsString:@"MessageArea"];
            if (!hit) continue;

            [out appendFormat:@"CLASS: %@\n", cn];
            unsigned int mc = 0;
            Method *methods = class_copyMethodList(classes[i], &mc);
            for (unsigned int j = 0; j < mc; j++) {
                NSString *sel = NSStringFromSelector(method_getName(methods[j]));
                NSString *low = sel.lowercaseString;
                if ([low containsString:@"send"] || [low containsString:@"schedule"]
                    || [low containsString:@"enqueue"] || [low containsString:@"deliver"]) {
                    [out appendFormat:@"   -[%@ %@] args=%u\n",
                     cn, sel, (unsigned)method_getNumberOfArguments(methods[j])];
                }
            }
            free(methods);
        }
        free(classes);
        logAppend(out);
    }
}

// ── Установка хука (без substrate, обычный swizzle через IMP) ──
static BOOL bypass = NO;

static void install(NSString *clsName, NSString *selName, BOOL hasArg) {
    Class cls = objc_getClass(clsName.UTF8String);
    if (!cls) { logAppend([NSString stringWithFormat:@"✗ нет класса: %@", clsName]); return; }
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { logAppend([NSString stringWithFormat:@"✗ нет метода: %@ %@", clsName, selName]); return; }

    if (hasArg) {
        void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^(id selfObj, id arg) {
            if (bypass) { bypass = NO; orig(selfObj, sel, arg); return; }
            __weak id ws = selfObj;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDelay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                id s = ws; if (!s) return;
                bypass = YES;
                orig(s, sel, arg);
            });
        });
        method_setImplementation(m, newImp);
    } else {
        void (*orig)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
        IMP newImp = imp_implementationWithBlock(^(id selfObj) {
            if (bypass) { bypass = NO; orig(selfObj, sel); return; }
            __weak id ws = selfObj;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDelay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                id s = ws; if (!s) return;
                bypass = YES;
                orig(s, sel);
            });
        });
        method_setImplementation(m, newImp);
    }
    logAppend([NSString stringWithFormat:@"✅ ПЕРЕХВАЧЕН: %@ %@", clsName, selName]);
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        logAppend(@"== TgSendDelay loaded ==");
        scanAndReport();

        NSArray *cands = @[
            @[@"ChatController",      @"sendMessages:",     @YES],
            @[@"ChatController",      @"sendMessage:",      @YES],
            @[@"ChatController",      @"sendCurrentMessage:", @YES],
            @[@"ChatController",      @"sendMessages",      @NO],
            @[@"ChatController",      @"sendMessage",       @NO],
            @[@"ChatController",      @"sendCurrentMessage",@NO],
            @[@"ChatControllerImpl",  @"sendMessages:",     @YES],
        ];
        for (NSArray *c in cands) {
            install(c[0], c[1], [c[2] boolValue]);
        }
        logAppend(@"== hooks attempted ==");
    }
}
