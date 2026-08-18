#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static double kDelaySeconds = 12.0;

%hook ChatController
- (void)sendMessages:(id)messages {
    // Реальная точка отправки. Заменяем мгновенную отправку на
    // отложенную schedule_date, как в AyuGram — см. хук ниже.
    %orig(messages);
}
%end