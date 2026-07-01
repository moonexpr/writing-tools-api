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
#import <Security/Security.h>

// PCC uses a restricted managed entitlement. Touching PrivateCloudComputeLanguageModel
// without it is a fatalError (unsigned) or an AMFI SIGKILL (ad-hoc). Check ourselves
// first so --pcc degrades to a message instead of crashing the process.
static BOOL HasPCCEntitlement(void) {
    SecTaskRef task = SecTaskCreateFromSelf(NULL);
    if (!task) return NO;
    CFTypeRef v = SecTaskCopyValueForEntitlement(
        task, CFSTR("com.apple.developer.private-cloud-compute"), NULL);
    BOOL ok = (v == kCFBooleanTrue);
    if (v) CFRelease(v);
    CFRelease(task);
    return ok;
}
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

// Pack text into chunks <= budget chars, preferring paragraph then sentence
// boundaries so structure is preserved; hard-splits only an over-long sentence.
static NSArray<NSString *> *ChunkText(NSString *text, NSUInteger budget) {
    NSMutableArray<NSString *> *chunks = [NSMutableArray array];
    NSMutableString *cur = [NSMutableString string];
    void (^flush)(void) = ^{
        if (cur.length) { [chunks addObject:[cur copy]]; [cur setString:@""]; }
    };
    for (NSString *para in [text componentsSeparatedByString:@"\n"]) {
        if (para.length <= budget) {
            if (cur.length + para.length + 1 > budget) flush();
            if (cur.length) [cur appendString:@"\n"];
            [cur appendString:para];
            continue;
        }
        flush();  // oversized paragraph: break into sentences
        NSMutableString *sc = [NSMutableString string];
        for (NSString *s in [para componentsSeparatedByString:@". "]) {
            NSString *piece = [s stringByAppendingString:@". "];
            if (piece.length > budget) {                 // pathological: hard split
                if (sc.length) { [chunks addObject:[sc copy]]; [sc setString:@""]; }
                for (NSUInteger i = 0; i < piece.length; i += budget) {
                    NSUInteger len = MIN(budget, piece.length - i);
                    [chunks addObject:[piece substringWithRange:NSMakeRange(i, len)]];
                }
                continue;
            }
            if (sc.length + piece.length > budget) {
                [chunks addObject:[sc copy]]; [sc setString:@""];
            }
            [sc appendString:piece];
        }
        if (sc.length) [chunks addObject:[sc copy]];
    }
    flush();
    return chunks;
}

// Map each chunk through the model on-device, then combine: reduce (re-run the
// mode over joined outputs) for summarize/outline; concatenate for the rest.
static int AIChunked(AIWriter *ai, NSString *mode, NSString *instruction,
                     NSString *text, NSUInteger budget) {
    NSArray<NSString *> *chunks = ChunkText(text, budget);
    fprintf(stderr, "ai: large input — processing on-device in %lu chunks\n",
            (unsigned long)chunks.count);

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger i = 0;
    for (NSString *c in chunks) {
        fprintf(stderr, "ai: chunk %lu/%lu\n", (unsigned long)++i,
                (unsigned long)chunks.count);
        NSString *r = [ai runWithInstruction:instruction text:c usePCC:NO];
        if ([r isEqualToString:@"ERROR_CONTEXT"] || [r hasPrefix:@"ERROR:"]) {
            fprintf(stderr, "ai: chunk %lu failed: %s\n", (unsigned long)i, r.UTF8String);
            return 1;
        }
        [parts addObject:r];
    }

    BOOL reduce = [mode isEqualToString:@"summarize"] || [mode isEqualToString:@"outline"];
    NSString *combined;
    if (reduce) {
        NSString *joined = [parts componentsJoinedByString:@"\n"];
        while (joined.length > budget) {                 // multi-level reduce
            NSMutableArray<NSString *> *red = [NSMutableArray array];
            for (NSString *s in ChunkText(joined, budget)) {
                NSString *r = [ai runWithInstruction:instruction text:s usePCC:NO];
                [red addObject:([r hasPrefix:@"ERROR"] ? @"" : r)];
            }
            joined = [red componentsJoinedByString:@"\n"];
        }
        combined = [ai runWithInstruction:instruction text:joined usePCC:NO];
    } else {
        combined = [parts componentsJoinedByString:@"\n\n"];
    }
    printf("%s\n", combined.UTF8String);
    return 0;
}

static int AI(NSString *mode, BOOL usePCC, NSString *text) {
    if (text.length == 0) { fprintf(stderr, "ai: empty input\n"); return 1; }
    if (!usePCC && ![AIWriter isAvailable]) {
        fprintf(stderr, "ai: on-device model unavailable\n");
        return 1;
    }
    if (usePCC && !HasPCCEntitlement()) {
        fprintf(stderr,
            "ai: --pcc needs the 'com.apple.developer.private-cloud-compute' "
            "entitlement,\n    which Apple must grant to your developer account and "
            "embed via a\n    provisioning profile. An unsigned CLI can't use it "
            "(AMFI kills it).\n    Build/sign this as an entitled .app, or stay "
            "on-device (4096-token cap).\n");
        return 3;
    }
    NSDictionary<NSString *, NSString *> *prompts = @{
        @"proofread": @"You are a proofreader. Correct the spelling, grammar, and "
                       "punctuation of the user's text. Return only the corrected "
                       "text, with no commentary.",
        @"rewrite":   @"Rewrite the user's text to be clearer and more professional. "
                       "Return only the rewritten text, with no commentary.",
        @"summarize": @"Summarize the user's text in one or two concise sentences. "
                       "Return only the summary, with no commentary.",
        @"simplify":  @"Rewrite the user's text in simpler, plainer language while "
                       "preserving its original narrative structure, the order of "
                       "ideas, and all of its points. Keep the same flow and roughly "
                       "the same length — do NOT condense it into a summary. Use "
                       "shorter sentences and everyday words. Return only the "
                       "rewritten text, with no commentary.",
        @"outline":   @"Turn the user's text into a plain-text outline that follows "
                       "its narrative structure in order. Use simple numbered lines "
                       "(1., 2., 3.) for top-level points and space indentation for "
                       "sub-points. Keep each line short and in plain language. "
                       "Return only the outline, with no commentary.",
    };
    // Force plaintext: the on-device model otherwise tends to wrap output in Markdown.
    NSString *plaintext = @" Output plain text only. Do not use Markdown, code fences, "
                           "asterisks, backticks, headings, or bullet characters.";
    NSString *instruction =
        [(prompts[mode] ?: prompts[@"proofread"]) stringByAppendingString:plaintext];

    AIWriter *ai = [AIWriter new];
    // Auto-chunk large input on-device so >4K-token docs work without PCC. Output
    // ≈ input for proofread/simplify/rewrite, so those get a tighter per-chunk budget.
    BOOL smallOutput = [mode isEqualToString:@"summarize"] || [mode isEqualToString:@"outline"];
    NSUInteger budget = smallOutput ? 9000 : 5000;   // chars (~2250 / ~1250 tokens)
    if (!usePCC && text.length > budget) {
        return AIChunked(ai, mode, instruction, text, budget);
    }

    NSString *out = [ai runWithInstruction:instruction text:text usePCC:usePCC];

    if ([out isEqualToString:@"ERROR_CONTEXT"]) {
        if (usePCC) {
            fprintf(stderr, "ai: input exceeds the Private Cloud Compute limit "
                            "(32768 tokens).\n");
        } else {
            fprintf(stderr, "ai: input exceeds the on-device limit (4096 tokens). "
                            "Retry with the larger cloud model:\n"
                            "    wtsurface ai --pcc %s\n", mode.UTF8String);
        }
        return 2;
    }
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
            // Parse: ai [--pcc] [mode]   (flag order-independent; mode = first non-flag)
            BOOL usePCC = NO;
            NSString *mode = @"proofread";
            for (int i = 2; i < argc; i++) {
                NSString *a = @(argv[i]);
                if ([a isEqualToString:@"--pcc"]) usePCC = YES;
                else mode = a;
            }
            return AI(mode, usePCC, text);
        }
#endif
        return Proofread(text);
    }
}
