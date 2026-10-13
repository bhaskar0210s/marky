#import "Typeset.h"
#import "MTMathListBuilder.h"
#import "MTTypesetter.h"

MTMathListDisplay *MKTypeset(NSString *tex, MTFont *font, BOOL display, NSString **reason) {
    @try {
        MTMathListBuilder *builder = [[MTMathListBuilder alloc] initWithString:tex];
        MTMathList *list = [builder build];
        if (!list || builder.error) {
            *reason = builder.error.localizedDescription ?: @"Unreadable formula";
            return nil;
        }
        return [MTTypesetter createLineForMathList:list font:font style:display ? kMTLineStyleDisplay : kMTLineStyleText];
    } @catch (NSException *exception) {
        *reason = exception.reason ?: @"Unreadable formula";
        return nil;
    }
}
