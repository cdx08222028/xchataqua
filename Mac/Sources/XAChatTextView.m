/* X-Chat Aqua
 * Copyright (C) 2002 Steve Green
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA */

#include "text.h"
#include "url.h"
// TBD: This is for urlhander_list Should we pass this in?

#import "XAChatTextView.h"
#import "ColorPalette.h"
#import "ChatViewController.h"
#import "MIRCString.h"
#import "MenuMaker.h"

#import "SystemVersion.h" // for OS X file:/// crash workaround

static NSAttributedString *XAChatTextViewNewLine;
//static NSAttributedString *tab;
static NSCursor *XAChatTextViewSizableCursor;

@implementation XAChatTextView
@synthesize palette=_palette;
@synthesize style=_style;
@synthesize scrollingBack=_scrollingBack;

+ (void)initialize {
    [super initialize];
    XAChatTextViewNewLine = [[NSAttributedString alloc] initWithString:@"\n"];
    //tab = [[NSAttributedString alloc] initWithString:@"\t"];

    XAChatTextViewSizableCursor = [[NSCursor alloc] initWithImage:[NSImage imageNamed:@"lr_cursor.tiff"] hotSpot:NSMakePoint (8,8)];
}

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self != nil) {
        wordRange = NSMakeRange(NSNotFound, 0);
        fontSize = NSMakeSize(10, 20);

        _style = [[NSMutableParagraphStyle alloc] init];

        [self setRichText:YES];
        [self setEditable:NO];

        [self registerForDraggedTypes:@[NSFilenamesPboardType]];
    }
    return self;
}

- (void) awakeFromNib
{
    // Scrolling is achieved by moving the origin of the NSClipView's bounds rectangle.
    // So you can receive notification of changes to the scroll position by adding yourself
    // as an observer of NSViewBoundsDidChangeNotification for the NSScrollView's NSClipView
    // ([theScrollView contentView]).

    [[NSNotificationCenter defaultCenter] addObserver:self
                                            selector:@selector(updateAtBottom:)
                                                name:@"NSViewBoundsDidChangeNotification"
                                              object:[self superview]];
    [self updateAtBottom:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(frameChanged:)
                                                 name:@"NSViewFrameDidChangeNotification"
                                               object:self];
}

- (void) dealloc
{
    self.palette = nil;
    self.style = nil;
    [normalFont release];
    [boldFont release];
    [word release];

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [super dealloc];
}

- (void) copy:(id)sender
{
    // Perform the "copy" operation.

    // Setup the pasteboard
    NSPasteboard *pb = [NSPasteboard generalPasteboard];

    NSArray *types = @[NSStringPboardType, NSRTFPboardType];
    [pb declareTypes:types owner:self];

    NSRange selection = [self selectedRange];
    NSTextStorage *stg = [self textStorage];

    // Get the selected text
    NSAttributedString *attr_string = [stg attributedSubstringFromRange:selection];

    // Plain text version.  Convert tabs to spaces.
    NSString *plain = [attr_string string];
    NSMutableString *pstripped = [plain mutableCopyWithZone:nil];
    [pstripped replaceOccurrencesOfString:@"\t"
                               withString:@" "
                                  options:NSLiteralSearch
                                    range:NSMakeRange(0, [pstripped length])];

    [pb setString:pstripped forType:NSStringPboardType];

    // RTF version.  Remove the hidden text completely.
    NSMutableAttributedString *rstripped = [attr_string mutableCopyWithZone:nil];
    NSRange range = NSMakeRange(0, [rstripped length]);
    while (range.length > 0)
    {
        NSRange ret;

        id font = [rstripped attribute:NSFontAttributeName
                               atIndex:range.location
                 longestEffectiveRange:&ret
                               inRange:range];

        if (font == [MIRCString hiddenFont])
        {
            [rstripped deleteCharactersInRange:ret];
            range.length -= ret.length;
        }
        else
        {
            range.location += ret.length;
            range.length -= ret.length;
        }
    }

    NSData *rtfData = [rstripped RTFFromRange:(NSMakeRange(0, [rstripped length]))
                           documentAttributes:@{}];
    [pb setData:rtfData forType:NSRTFPboardType];
    [rstripped release];
    [pstripped release];
}

- (void) setDropHandler:(id) handler
{
    self->dropHandler = handler;
}

- (NSDragOperation) draggingEntered:(id <NSDraggingInfo>) sender
{
    return [self draggingUpdated:sender];
}

- (NSDragOperation) draggingUpdated:(id <NSDraggingInfo>) sender
{
    if (!dropHandler /* || [self isHiddenOrHasHiddenAncestor] */) {
        return NSDragOperationNone;
    }

    NSPasteboard *pboard = [sender draggingPasteboard];

    if (![[pboard types] containsObject:NSFilenamesPboardType]) {
        return NSDragOperationNone;
    }

    return NSDragOperationCopy;
}

- (BOOL) performDragOperation:(id <NSDraggingInfo>) info
{
    return [dropHandler processFileDrop:info forUser:nil];
}

- (void)setPalette:(ColorPalette *)object
{
    [_palette autorelease];
    _palette = [object retain];

    [self setBackgroundColor:[_palette getColor:XAColorBackground]];
}

- (void)adjustMargin {
    CGFloat indent = prefs.xa_text_manual_indent_chars * fontSize.width;

    NSMutableParagraphStyle *style = [[[NSMutableParagraphStyle alloc] init] autorelease];

    NSTextTab *tabStop = [[[NSTextTab alloc] initWithType:NSRightTabStopType location:indent] autorelease];
    [style setTabStops:@[tabStop]];
    [style setLineHeightMultiple:prefs.xa_line_height / 100.0];

    indent += fontSize.width;

    CGFloat newLineRectX = floor (indent + fontSize.width * 2 / 3) - 2;
    if (newLineRectX == lineRect.origin.x) {
        return;
    }

    lineRect.origin.x = newLineRectX;

    indent += fontSize.width;

    [style setHeadIndent:indent];
    for (NSInteger i = 0; i < 30; i ++)
    {
        NSTextTab *tabStop = [[[NSTextTab alloc] initWithType:NSLeftTabStopType location:indent] autorelease];
        [style addTabStop:tabStop];
        indent += fontSize.width;
    }

    self.style = style;

    NSMutableAttributedString *storage = [self textStorage];
    NSRange whole = NSMakeRange (0, storage.length);
    [storage beginEditing];
    [storage removeAttribute:NSParagraphStyleAttributeName
        range:whole];
    [storage addAttribute:NSParagraphStyleAttributeName
        value:style range:whole];
    [storage endEditing];

    [[self window] invalidateCursorRectsForView:self];
    [self setNeedsDisplay:true];
}

- (void)setFont:(NSFont *)new_font boldFont:(NSFont *)new_boldFont
{
    NSFont *old_font = [normalFont autorelease];
//    NSFont *old_boldFont = [boldFont autorelease];

    normalFont = [new_font retain];
    boldFont = [new_boldFont retain];

    NSDictionary *attr = @{NSFontAttributeName: normalFont};
    fontSize = [@"-" sizeWithAttributes:attr];

    if (![new_font isEqual:old_font]) {   // CL: adjustMargin is VERY expensive, don't do it unless necessary
        [self adjustMargin];
    }

    // Apply changes
#if 0
// This is too damn slow!!
    NSMutableAttributedString *s = [self textStorage];
    for (NSUInteger i = 0; i < [s length]; )
    {
        NSRange r;
        NSRange limit = NSMakeRange (i, [s length] - i);
        NSDictionary *attr =
            [s attributesAtIndex:i longestEffectiveRange:&r inRange:limit];

        NSFont *of = [attr objectForKey:NSFontAttributeName];
        NSFont *nf = of == old_boldFont ? boldFont : normalFont;

        NSMutableDictionary *nattr = [attr mutableCopyWithZone:nil];
        [nattr setObject:nf forKey:NSFontAttributeName];

        //if ([attr objectForKey:NSParagraphStyleAttributeName])
            //[nattr setObject:style forKey:NSParagraphStyleAttributeName];

        [s setAttributes:nattr range:r];

        i += r.length;
    }
#endif
}

- (void)clearLinesIfFlooded
{
    if (prefs.max_lines == 0)
        return;

    int threshhold = prefs.max_lines + prefs.max_lines * 0.1;
    if (numberOfLines < threshhold)
        return;

    NSTextStorage *stg = [self textStorage];

    while (numberOfLines > prefs.max_lines)
    {
        NSString *s = [stg mutableString];
        NSRange firstLine = [s lineRangeForRange:NSMakeRange(0, 0)];
        if (NSEqualRanges(firstLine, NSMakeRange(0, [s length])))
            break;
        [stg deleteCharactersInRange:firstLine];
        numberOfLines--;
    }
}

- (void)setScrollingBack:(BOOL)scrollingBack {
    if (self->_scrollingBack == scrollingBack) return;

    self->_scrollingBack = scrollingBack;
    if (scrollingBack) {
        [self.textStorage beginEditing];
    } else {
        [self.textStorage endEditing];
        self->atBottom = YES;
        [self scrollPoint:NSMakePoint(0, NSMaxY([self bounds]))];
    }
}

- (void)printLine:(const char *)givenText length:(size_t)len stamp:(time_t)stamp {
    char buff[128];  // 128 = large enough for timestamp
    char *prepend = buff;

    if (stamp == 0) {
        stamp = time(NULL);
    }

    if (prefs.timestamp) {
        prepend += strftime(buff, sizeof(buff), prefs.stamp_format, localtime(&stamp));
    }

    char textBuffer[len + 1];
    char *text = textBuffer;
    strcpy(text, givenText);

    char *tmp = text;
    char *end = tmp + len;

    if (prefs.indent_nicks)
    {
        *prepend++ = '\t';

        tmp = strchr (text, '\t');
        if (tmp)
            tmp ++;
        else
            *prepend++ = '\t';
    }

    *prepend = 0;

    while (tmp && *tmp && tmp < end)    // Blast remaining tabs
    {
        if (*tmp == '\t')
            *tmp = ' ';
        tmp ++;
    }

    MIRCString *pre_str = [MIRCString stringWithUTF8String:buff
                                                    length:prepend - buff
                                                   palette:self.palette
                                                      font:normalFont
                                                  boldFont:boldFont];


    //---- HOTFIX upper case file:/// crash bug for OS X 10.8
    if ([SystemVersion minor] == 8) {
        NSString *cursedString = @(text);

        char cCursedWord[9] = "file:///";
        cCursedWord[0] = 'F'; // stupid runtime string builder not to kill the xcode
        NSString *cursedWord = @(cCursedWord);

        NSString *rescuedString = cursedString;
        if ([cursedString rangeOfString:cursedWord].location != NSNotFound) {
            rescuedString = [cursedString stringByReplacingOccurrencesOfString:cursedWord withString:@"file:///"];
        }
        text = (char *)[rescuedString UTF8String];
    }
    //---- End of HOTFIX

    MIRCString *msgString = [MIRCString stringWithUTF8String:text
                                                      length:len
                                                     palette:self.palette
                                                        font:normalFont
                                                    boldFont:boldFont];

    [pre_str appendAttributedString:msgString];
    [pre_str appendAttributedString:XAChatTextViewNewLine];

    [pre_str addAttribute:NSParagraphStyleAttributeName
                    value:self.style
                    range:NSMakeRange(0, [pre_str length])];

    long idx = [self.textStorage length];

    [self.textStorage appendAttributedString:pre_str];

    numberOfLines ++;

    NSString *s = [self.textStorage string];
    long slen = [self.textStorage length];

    for (; idx < slen; idx++) {
        NSUInteger word_start = idx;
        NSUInteger word_stop = idx;

        if (isspace ([s characterAtIndex:word_start]))
          continue;

        while (word_stop < slen && !isspace ([s characterAtIndex:word_stop+1]))
          word_stop ++;

        NSRange range = NSMakeRange (word_start, word_stop - word_start + 1);

        const char *normalizedName = NULL;
        int type = [self checkHotwordInRange:&range normalizedString:&normalizedName];

        if (type == WORD_URL)
        {
            NSString *substring = [s substringWithRange:range];
            if (substring) {
                substring = [substring stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithRange:NSMakeRange(' ', '~')]];
                NSURL *url = [NSURL URLWithString:substring];
                if (url)
                    [self.textStorage addAttribute:NSLinkAttributeName
                                             value:url
                                             range:range];
            }
        }
        else if (type == WORD_NICK && prefs.colorednicks)
        {
            const char *substring = [[s substringWithRange:range] UTF8String];
            NSColor *color;
            if (substring)
            {
                if (!strcasecmp(substring, [self currentSession]->me->nick))
                {
                    color = [self.palette getColor:XAColorNickMentioned];
                }
                else
                {
                    static char rcolors[] = { 19, 20, 22, 24, 25, 26, 27, 28, 29 };

                    long sum = 0;

                    if (normalizedName) {
                        while (*normalizedName)
                            sum += *normalizedName++;
                    } else {
                        for (unsigned long i = 0; i < range.location + range.length; i++)
                            sum += [s characterAtIndex:i];
                    }
                    sum %= sizeof (rcolors);
                    color = [self.palette getColor:rcolors[sum]];
                }
                [self.textStorage addAttribute:NSForegroundColorAttributeName
                                         value:color
                                         range:range];
            }
        }
        idx = word_stop;
    }
}

- (void)printLine:(const char *)text length:(size_t)len {
    [self printLine:text length:len stamp:time(NULL)];
}

- (void)printText:(NSString *)const_text {
    [self printText:const_text stamp:time(NULL)];
}

- (void)printText:(NSString *)aText stamp:(time_t)stamp {
    if (!self.isScrollingBack) {
        [self.textStorage beginEditing];
    }

    for (NSString *line in [aText componentsSeparatedByString:@"\n"]) {
        if ([line containsString:@"\007"]) {
            NSBeep();
            line = [line stringByReplacingOccurrencesOfString:@"\007" withString:@""]; // ???: Once @"" was @" "
        }
        const char *cLine = line.UTF8String;
        size_t len = strlen(cLine);
        if (len == 0) {
            continue;
        }
        [self printLine:cLine length:len stamp:stamp];
    }

    if (!self.isScrollingBack) {
        [self clearLinesIfFlooded];
        [self.textStorage endEditing];
    }

    if (atBottom)
        [self scrollPoint:NSMakePoint(0, NSMaxY([self frame]) - NSHeight([[self superview] bounds]))];
}

- (void)clearText {
    numberOfLines = 0;
    [self setString:@""];
}

- (void)updateAtBottom:(NSNotification *)notification
{
    NSClipView *clipView = (NSClipView *)[self superview];

    CGFloat dmax = NSMaxY(clipView.documentRect);
    CGFloat cmax = NSMaxY(clipView.documentVisibleRect);

    atBottom = (dmax < cmax + fontSize.height * 2) || (NSMaxY([self frame]) <= NSHeight([[self superview] bounds]));

    dlog(FALSE, @"Update at bottom: dmax=%f, cmax=%f, at_bottom=%d\n", dmax, cmax, atBottom);
}


- (void)frameChanged:(NSNotification *)notif
{
    if (atBottom)
        [self scrollPoint:NSMakePoint(0, NSMaxY([self frame]) - NSHeight([[self superview] bounds]))];
}

- (void)viewDidMoveToWindow
{
    [[self window] setAcceptsMouseMovedEvents:true];

    if (atBottom)
    {
        // Fake styling to refresh scrolling down
        NSTextStorage *stg = [self textStorage];
        if (stg.length > 1) {
            [stg addAttribute:NSBackgroundColorAttributeName
                        value:[NSColor clearColor]
                        range:NSMakeRange(stg.length-1, 1)];
        }
    }
    // Docs say that characterIndexForPoint will return -1 for a point that is out of range.
    // Practice says otherwise.
    // 24 Jan 06 - SBG
    // This crashes when joining channels with 1300+ users... it's useless anyway.
    //illegal_index = [self characterIndexForPoint:NSMakePoint (-100,-100)];
}

- (void)clear_hot_word
{
    if (word)
    {
        NSTextStorage *stg = [self textStorage];
        if (NSMaxRange(wordRange) <= [stg length]) {
            [stg removeAttribute:NSUnderlineStyleAttributeName range:wordRange];
        }
        [word release];
        word = nil;
        wordRange = NSMakeRange(NSNotFound, 0);
    }
}

- (void) resetCursorRects
{
    NSRect rect = self.visibleRect;
    lineRect = NSMakeRect(lineRect.origin.x, rect.origin.y, 5.0, rect.size.height);

    [self addCursorRect:lineRect cursor:XAChatTextViewSizableCursor];
}

/* CL: use our real session if possible, otherwise fall back on current_sess */
- (session *)currentSession
{
    id controller = [self delegate];
    if (![controller isKindOfClass:[ChatViewController class]]) {
        controller = nil;
    }
    return (controller ? [(ChatViewController *)controller session] : current_sess);
}

- (void)openLink
{
    const char *cmd = NULL;

    switch (wordType)
    {
        case WORD_URL:
            // processed by native support
            break;
        case WORD_HOST:
        case WORD_EMAIL:
            cmd = prefs.xa_urlcommand;
            break;

        case WORD_NICK:
            cmd = prefs.xa_nickcommand;
            break;

        case WORD_CHANNEL:
            cmd = prefs.xa_channelcommand;
            break;

        default:
            return;
    }

    nick_command_parse ([self currentSession], (char *) cmd, (char *) [word UTF8String], (char *) [word UTF8String]);

    [self clear_hot_word];
}

// nick indent
- (void) mouseDown:(NSEvent *) theEvent
{
    NSPoint point = [theEvent locationInWindow];
    NSPoint where = [self convertPoint:point fromView:nil];

    if (!NSPointInRect (where, lineRect))
    {
        [super mouseDown:theEvent];    // Superclass will block until mouseUp
        if (word && [self selectedRange].length == 0 && [self currentSession]) {
            [self openLink];
        }
        return;
    }

    int margin = prefs.xa_text_manual_indent_chars;

    for (;;)
    {
        NSEvent *nextEvent = [[self window] nextEventMatchingMask:NSEventMaskLeftMouseUp|NSEventMaskLeftMouseDragged];

        if ([nextEvent type] == NSEventTypeLeftMouseUp)
            break;

        NSPoint mouseLoc = [self convertPoint:[nextEvent locationInWindow] fromView:nil];

        int new_margin = (int)(mouseLoc.x / fontSize.width) - 1;

        if (new_margin > 2 && new_margin < 50 && new_margin != margin)
        {
            margin = new_margin;
            prefs.xa_text_manual_indent_chars = margin;
            [self adjustMargin];
        }
    }
}

- (NSMenu *) menuForEvent:(NSEvent *) theEvent
{
    session *sess = [self currentSession];

    NSRange sel = [self selectedRange];
    if (sel.location != NSNotFound && sel.length > 0)
    {
        NSMenu *m = [[super menuForEvent:theEvent] copyWithZone:nil];

        NSString *text = [[[self textStorage] string] substringWithRange:sel];

        NSMenu *url_menu = [[MenuMaker defaultMenuMaker] menuForURL:text inSession:sess];
        NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:@"URL Actions" action:nil keyEquivalent:@""];
        [i setSubmenu:url_menu];
        [m addItem:i];
        [i release];

        NSMenu *nick_menu = [[MenuMaker defaultMenuMaker] menuForNick:text inSession:sess];
        i = [[NSMenuItem alloc] initWithTitle:@"Nick Actions" action:nil keyEquivalent:@""];
        [i setSubmenu:nick_menu];
        [m addItem:i];
        [i release];

        return [m autorelease];
    }

    if (word)
    {
        [[NSRunLoop currentRunLoop] performSelector:@selector (clear_hot_word)
                                             target:self argument:nil order:1
                                              modes:@[NSDefaultRunLoopMode]];

        switch (wordType)
        {
            case WORD_HOST:
            case WORD_URL:
                return [[MenuMaker defaultMenuMaker] menuForURL:word inSession:sess];

            case WORD_NICK:
                return [[MenuMaker defaultMenuMaker] menuForNick:word inSession:sess];

            case WORD_CHANNEL:
                return [[MenuMaker defaultMenuMaker] menuForChannel:word inSession:sess];

            case WORD_EMAIL:
                return [[MenuMaker defaultMenuMaker] menuForURL:[@"mailto:%@" format:word] inSession:sess];
        }
    }

    // TBD:
    // if (sess->type == dialog)
    //   return [[AquaChat sharedAquaChat] nickMenuForServer:current_sess->server
    //                            nick:[NSString stringWithUTF8String:sess->channel]];

    return [super menuForEvent:theEvent];
}

- (int)checkHotwordInRange:(NSRangePointer)range normalizedString:(const char**)string
{
    session *sess = [self currentSession];
    NSString *text = [[self textStorage] string];
    bool nickOnly = FALSE;

    struct User *user = NULL;

    // First, strip any brackets and remove trailing commas
    unichar c;
    while (range->length > 2 &&
           ((c = [text characterAtIndex: (range->location + range->length - 1)]),
            (c == ',' || c == ')' || c == ']' || c == '}' || c == '>')))
        range->length--;

    while (range->length > 2 &&
           ((c = [text characterAtIndex: range->location]),
            (c == '(' || c == '[' || c == '{' || c == '<')))
    {
        range->location++;
        range->length--;
    }

    for (;;)
    {
        char *cword = (char *)[[text substringWithRange:*range] UTF8String];
        if (!cword)
            return 0;
        size_t len = strlen(cword);// range->length;

        // Let common have first crack at it.
        int ret = nickOnly ? 0 : url_check_word (cword, len);    /* common/url.c */

        // If we get something from common, double check a few things..
        if (ret)
        {
            // Check for @#channel, and chop off the @ (or any nick prefix)
            if (ret == WORD_CHANNEL && strchr (sess->server->nick_prefixes, cword[0]))
            {
                range->location++;
                range->length--;
            }

            return ret;
        }

        //
        // Else, check for stuff that common doesn't.
        //

        // @nick
        if (strchr (sess->server->nick_prefixes, cword[0]) && (user = userlist_find (sess, cword+1)))
        {
            range->location++;
            range->length--;
            if (string)
                *string = user->nick;
            return WORD_NICK;
        }

        // Just plain nick
        if ((user = userlist_find (sess, cword)))
        {
            if (string)
                *string = user->nick;
            return WORD_NICK;
        }

        // What does this do?
        //if (sess->type == SESS_DIALOG)
        //    return WORD_DIALOG;

        // Check for words surrounded in brackets.
        // Narrow the range and try again.
        NSRange aposRange;
        if ((!isalpha(*cword) && *cword == cword[len - 1]))
        {
            if (range->length < 3) break;    /* check this before subtracting; length is unsigned */
            range->location++;
            range->length -= 2;
            continue;
        }
        else if (!isalnum(cword[len - 1]))
        {
            if (range->length < 2) break;
            range->length--;
            nickOnly = true;
            continue;
        }
        else if (!isalnum(*cword))
        {
            if (range->length < 2) break;
            range->location++;
            range->length--;
            continue;
        }
        else if ((aposRange = [text rangeOfString:@"'" options:NSBackwardsSearch range:*range]).location != NSNotFound)
        {
            // Try backing up to the last apostrophe (might find a nick match)
            range->length = aposRange.location - range->location;
            nickOnly = true;
            continue;
        }

        return 0;
    }

    return 0;
}

- (void)mouseMoved:(NSEvent *)theEvent {
    // TBD: The use of 'superview' below assumes we live in a scroll view
    //      which is not always true.
    if (![self window] || ![NSApplication event:theEvent inView:[self superview]])
    {
        [self clear_hot_word];
        return;
    }

    NSRect pointRect = NSZeroRect;
    pointRect.origin = [theEvent locationInWindow];
    NSRect where = [[theEvent window] convertRectToScreen:pointRect];
    NSUInteger idx = [self characterIndexForPoint:where.origin];

    NSTextStorage *stg = [self textStorage];

    if (word)
    {
        if (NSLocationInRange(idx, wordRange))
            return;
        [self clear_hot_word];
    }

    NSString *s = [stg string];
    NSUInteger slen = [s length];

    if (slen == 0)
        return;

    if (slen == idx)
        return;

    if (isspace ([s characterAtIndex:idx]))
        return;

    // From this point, we know we have a selection...

    NSUInteger word_start = idx;
    NSUInteger word_stop = idx;

    while (word_start > 0 && !isspace ([s characterAtIndex:word_start-1]))    /* CL: maybe this should be iswspace, or a test using whitespaceAndNewlineCharacterSet? */
        word_start --;

    while (word_stop < slen && !isspace ([s characterAtIndex:word_stop+1]))
        word_stop ++;

    wordRange = NSMakeRange (word_start, word_stop - word_start + 1);

    wordType = [self checkHotwordInRange:&wordRange normalizedString:nil];
/*    wordType = my_text_word_check (s, &word_start, &word_stop);    */

    if (wordType <= 0)
        return;

    word = [[s substringWithRange:wordRange] retain];

    [stg addAttribute:NSUnderlineStyleAttributeName
                value:@(NSUnderlineStyleSingle)
                range:wordRange];
}

- (void) keyDown:(NSEvent *) theEvent
{
    // We got a key event, and but we don't want it.
    // Set the first responder, and forward the event..
    // .. just make sure we don't recurse.
    [[self window] selectNextKeyView:self];
    if ([[self window] firstResponder] != self)
        [[[self window] firstResponder] keyDown:theEvent];
}

#if 1
- (void) drawRect:(NSRect) aRect
{
    [super drawRect:aRect];

    if (!prefs.show_separator || !prefs.indent_nicks)
    {
        return;
    }

    [[self.palette getColor:XAColorForeground] set];
    [[NSGraphicsContext currentContext] setShouldAntialias:false];
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p setLineWidth:1];
    [p moveToPoint:NSMakePoint (lineRect.origin.x + 1, aRect.origin.y)];
    [p lineToPoint:NSMakePoint (lineRect.origin.x + 1, aRect.origin.y + aRect.size.height)];
    [p stroke];
}
#endif

@end
