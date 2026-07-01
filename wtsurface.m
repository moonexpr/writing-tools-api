// wtsurface.m — surface macOS text tools from Objective-C, without the
// Writing Tools menu that the macOS 27 "Siri AI" beta removed.
//
// Two subcommands, both built on PUBLIC AppKit API:
//   proofread   NSSpellChecker grammar+spelling on stdin -> report + corrected text
//   summarize   NSPerformService(@"Summarize", ...) on stdin -> system Summary panel
//
// Build:
//   clang -fobjc-arc -fmodules -framework Foundation -framework AppKit \
//         wtsurface.m -o wtsurface -isysroot "$(xcrun --show-sdk-path)"
//
// Usage:
//   echo "teh quick brown fox jumpd over teh lazi dog" | ./wtsurface proofread
//   pbpaste | ./wtsurface summarize

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// Built with build.sh (-DWT_HAVE_AI) to link the Swift Apple Intelligence shim.
// Without it, the tool still builds as pure Obj-C (proofread + summarize only).
#ifdef WT_HAVE_AI
#import "wtkit-Swift.h"
#endif

static NSString *ReadStdin(void) {
    NSData *data = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// ---- proofread: NSSpellChecker (spelling + grammar), public API ----
static int Proofread(NSString *text) {
    if (text.length == 0) { fprintf(stderr, "proofread: empty input\n"); return 1; }

    NSSpellChecker *checker = [NSSpellChecker sharedSpellChecker];
    NSInteger tag = [NSSpellChecker uniqueSpellDocumentTag];
    NSTextCheckingTypes types = NSTextCheckingTypeSpelling | NSTextCheckingTypeGrammar;

    NSArray<NSTextCheckingResult *> *results =
        [checker checkString:text
                       range:NSMakeRange(0, text.length)
                       types:types
                     options:nil
      inSpellDocumentWithTag:tag
                 orthography:NULL
                   wordCount:NULL];

    fprintf(stdout, "== issues (%lu) ==\n", (unsigned long)results.count);
    NSMutableString *corrected = [text mutableCopy];

    // Apply fixes back-to-front so earlier ranges stay valid.
    for (NSTextCheckingResult *r in [results reverseObjectEnumerator]) {
        if (r.resultType == NSTextCheckingTypeSpelling) {
            NSString *bad = [text substringWithRange:r.range];
            NSArray<NSString *> *guesses =
                [checker guessesForWordRange:r.range inString:text language:nil
                       inSpellDocumentWithTag:tag];
            NSString *fix = guesses.firstObject;
            fprintf(stdout, "  spelling  '%s' -> '%s'\n",
                    bad.UTF8String, fix ? fix.UTF8String : "(no suggestion)");
            if (fix) [corrected replaceCharactersInRange:r.range withString:fix];
        } else if (r.resultType == NSTextCheckingTypeGrammar) {
            for (NSDictionary *d in r.grammarDetails) {
                NSString *desc = d[NSGrammarUserDescription];
                NSArray *corr  = d[NSGrammarCorrections];
                fprintf(stdout, "  grammar   %s%s%s\n",
                        desc.UTF8String ?: "issue",
                        corr.count ? " -> " : "",
                        corr.count ? [corr.firstObject UTF8String] : "");
            }
        }
    }
    fprintf(stdout, "\n== corrected ==\n%s\n", corrected.UTF8String);
    return 0;
}

// ---- summarize: NSPerformService bridges to com.apple.SummaryService ----
static int Summarize(NSString *text) {
    if (text.length == 0) { fprintf(stderr, "summarize: empty input\n"); return 1; }
    [NSApplication sharedApplication];            // service bus needs an app context
    NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
    BOOL ok = NSPerformService(@"Summarize", pb); // opens the system Summary panel
    if (!ok) { fprintf(stderr, "summarize: service unavailable\n"); return 1; }
    [NSApp run];                                  // keep alive so the panel shows
    return 0;
}

// ---- ai: Apple Intelligence via the FoundationModels Swift shim ----
#ifdef WT_HAVE_AI
static int AI(NSString *mode, NSString *text) {
    if (text.length == 0) { fprintf(stderr, "ai: empty input\n"); return 1; }
    if (![AIWriter isAvailable]) {
        fprintf(stderr, "ai: on-device model unavailable\n");
        return 1;
    }
    NSDictionary<NSString *, NSString *> *prompts = @{
        @"proofread": @"You are a proofreader. Correct the spelling, grammar, and "
                       "punctuation of the user's text. Return only the corrected "
                       "text, with no commentary.",
        @"rewrite":   @"Rewrite the user's text to be clearer and more professional. "
                       "Return only the rewritten text, with no commentary.",
        @"summarize": @"Summarize the user's text in one or two concise sentences. "
                       "Return only the summary, with no commentary.",
    };
    NSString *instruction = prompts[mode] ?: prompts[@"proofread"];
    NSString *out = [[AIWriter new] runWithInstruction:instruction text:text];
    printf("%s\n", out.UTF8String);
    return [out hasPrefix:@"ERROR:"] ? 1 : 0;
}
#endif

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *cmd = argc > 1 ? @(argv[1]) : @"proofread";
        NSString *text = ReadStdin();
        if ([cmd isEqualToString:@"summarize"]) return Summarize(text);
#ifdef WT_HAVE_AI
        if ([cmd isEqualToString:@"ai"]) {
            NSString *mode = argc > 2 ? @(argv[2]) : @"proofread";
            return AI(mode, text);
        }
#endif
        return Proofread(text);
    }
}
