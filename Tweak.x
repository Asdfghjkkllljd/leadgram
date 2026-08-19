#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ═══════════════ НАСТРОЙКА ═══════════════
static const NSTimeInterval kDelay = 12.0;          // задержка в секундах
static NSString *const kEnabledKey = @"SendDelayEnabled";
// ═════════════════════════════════════════

static BOOL bypass = NO;
static BOOL enabled = YES;

// ── Безопасная установка хука: метод не найден → просто молчим ──
static void TgInstallSendDelay(NSString *className, NSString *selName) {
    Class cls = objc_getClass(className.UTF8String);
    if (!cls) {
        NSLog(@"[TgSendDelay] класс не найден: %@", className);
        return;
    }
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != 3) {   // self, _cmd, 1 аргумент
        NSLog(@"[TgSendDelay] метод не найден/не подходит: %@ %@", className, selName);
        return;
    }
    IMP orig = method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^(id selfObj, id messages) {
        void (*origFunc)(id, SEL, id) = (void (*)(id, SEL, id))orig;

        // Свой переотправленный вызов — пропускаем сразу
        if (bypass) {
            bypass = NO;
            origFunc(selfObj, sel, messages);
            return;
        }
        if (!enabled) {
            origFunc(selfObj, sel, messages);
            return;
        }

        // ⏳ НЕ отправляем сейчас. Сообщение уйдёт через kDelay секунд.
        // Пока идёт задержка — сетевой пакет не шлётся, онлайна нет.
        __weak id weakSelf = selfObj;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                         (int64_t)(kDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id strongSelf = weakSelf;
            if (!strongSelf) return;
            bypass = YES;
            origFunc(strongSelf, sel, messages);
        });
    });
    method_setImplementation(m, newImp);
    NSLog(@"[TgSendDelay] ✅ хук установлен: %@ %@", className, selName);
}

__attribute__((constructor))
static void TgSendDelayInit(void) {
    NSLog(@"[TgSendDelay] loaded ✅");

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kEnabledKey] == nil) [d setBool:YES forKey:kEnabledKey];
    enabled = [d boolForKey:kEnabledKey];

    // ── Кандидаты точек отправки (Telegram-iOS / Swiftgram) ──
    // Если при тесте сработал не тот — замени на точные имена
    // из class-dump твоего билда (инструкция в конце).
    NSArray *candidates = @[
        @[@"ChatController",      @"sendMessages:"],
        @[@"ChatController",      @"sendMessage:"],
        @[@"ChatController",      @"sendCurrentMessage:"],
        @[@"ChatController",      @"send:"],
        @[@"ChatController",      @"sendMessages"],
        @[@"ChatControllerImpl",  @"sendMessages:"],
    ];
    for (NSArray *c in candidates) {
        TgInstallSendDelay(c[0], c[1]);
    }
}
