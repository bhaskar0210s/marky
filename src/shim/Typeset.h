// Parses and typesets a formula from Objective-C, where the typesetter's exceptions can be caught.

#import <Foundation/Foundation.h>

@class MTFont, MTMathListDisplay;

NS_ASSUME_NONNULL_BEGIN

/// Typesets `tex`, or returns nil and a reason when it cannot. Swift cannot catch Objective-C
/// exceptions, so one raised by the typesetter would otherwise stop the whole page's layout.
MTMathListDisplay *_Nullable MKTypeset(NSString *tex, MTFont *font, BOOL display, NSString *_Nullable *_Nonnull reason);

NS_ASSUME_NONNULL_END
