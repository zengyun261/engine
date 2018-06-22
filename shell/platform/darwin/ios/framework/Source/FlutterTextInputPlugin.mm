// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterTextInputPlugin.h"

#include <UIKit/UIKit.h>

static const char _kTextAffinityDownstream[] = "TextAffinity.downstream";
static const char _kTextAffinityUpstream[] = "TextAffinity.upstream";

static UIKeyboardType ToUIKeyboardType(NSDictionary* type) {
  NSString* inputType = type[@"name"];
  if ([inputType isEqualToString:@"TextInputType.text"])
    return UIKeyboardTypeDefault;
  if ([inputType isEqualToString:@"TextInputType.multiline"])
    return UIKeyboardTypeDefault;
  if ([inputType isEqualToString:@"TextInputType.number"]) {
    if ([type[@"signed"] boolValue])
      return UIKeyboardTypeNumbersAndPunctuation;
    return UIKeyboardTypeDecimalPad;
  }
  if ([inputType isEqualToString:@"TextInputType.phone"])
    return UIKeyboardTypePhonePad;
  if ([inputType isEqualToString:@"TextInputType.emailAddress"])
    return UIKeyboardTypeEmailAddress;
  if ([inputType isEqualToString:@"TextInputType.url"])
    return UIKeyboardTypeURL;
  return UIKeyboardTypeDefault;
}

static UIReturnKeyType ToUIReturnKeyType(NSString* inputType) {
  if ([inputType isEqualToString:@"TextInputType.multiline"])
    return UIReturnKeyDefault;
  return UIReturnKeyDone;
}

static UITextAutocapitalizationType ToUITextAutocapitalizationType(NSString* inputType) {
  if ([inputType isEqualToString:@"TextInputType.text"])
    return UITextAutocapitalizationTypeSentences;
  if ([inputType isEqualToString:@"TextInputType.multiline"])
    return UITextAutocapitalizationTypeSentences;
  return UITextAutocapitalizationTypeNone;
}

#pragma mark - FlutterTextPosition

@implementation FlutterTextPosition

+ (instancetype)positionWithIndex:(NSUInteger)index {
  return [[[FlutterTextPosition alloc] initWithIndex:index] autorelease];
}

- (instancetype)initWithIndex:(NSUInteger)index {
  self = [super init];
  if (self) {
    _index = index;
  }
  return self;
}

@end

#pragma mark - FlutterTextRange

@implementation FlutterTextRange

+ (instancetype)rangeWithNSRange:(NSRange)range {
  return [[[FlutterTextRange alloc] initWithNSRange:range] autorelease];
}

- (instancetype)initWithNSRange:(NSRange)range {
  self = [super init];
  if (self) {
    _range = range;
  }
  return self;
}

- (UITextPosition*)start {
  return [FlutterTextPosition positionWithIndex:self.range.location];
}

- (UITextPosition*)end {
  return [FlutterTextPosition positionWithIndex:self.range.location + self.range.length];
}

- (BOOL)isEmpty {
  return self.range.length == 0;
}

- (id)copyWithZone:(NSZone*)zone {
  return [[FlutterTextRange allocWithZone:zone] initWithNSRange:self.range];
}

@end

@interface FlutterTextInputView : UIView <UITextInput>

// UITextInput
@property(nonatomic, readonly) NSMutableString* text;
@property(nonatomic, readonly) NSMutableString* markedText;
@property(readwrite, copy) UITextRange* selectedTextRange;
@property(nonatomic, strong) UITextRange* markedTextRange;
@property(nonatomic, copy) NSDictionary* markedTextStyle;
@property(nonatomic, assign) id<UITextInputDelegate> inputDelegate;

// UITextInputTraits
@property(nonatomic) UITextAutocapitalizationType autocapitalizationType;
@property(nonatomic) UITextAutocorrectionType autocorrectionType;
@property(nonatomic) UITextSpellCheckingType spellCheckingType;
@property(nonatomic) BOOL enablesReturnKeyAutomatically;
@property(nonatomic) UIKeyboardAppearance keyboardAppearance;
@property(nonatomic) UIKeyboardType keyboardType;
@property(nonatomic) UIReturnKeyType returnKeyType;
@property(nonatomic, getter=isSecureTextEntry) BOOL secureTextEntry;

@property(nonatomic, assign) id<FlutterTextInputDelegate> textInputDelegate;

@end

@implementation FlutterTextInputView {
  int _textInputClient;
  const char* _selectionAffinity;
  FlutterTextRange* _selectedTextRange;
}

@synthesize tokenizer = _tokenizer;

- (instancetype)init {
  self = [super init];

  if (self) {
    _textInputClient = 0;
    _selectionAffinity = _kTextAffinityUpstream;

    // UITextInput
    _text = [[NSMutableString alloc] init];
    _markedText = [[NSMutableString alloc] init];
    _selectedTextRange = [[FlutterTextRange alloc] initWithNSRange:NSMakeRange(0, 0)];

    // UITextInputTraits
    _autocapitalizationType = UITextAutocapitalizationTypeSentences;
    _autocorrectionType = UITextAutocorrectionTypeDefault;
    _spellCheckingType = UITextSpellCheckingTypeDefault;
    _enablesReturnKeyAutomatically = NO;
    _keyboardAppearance = UIKeyboardAppearanceDefault;
    _keyboardType = UIKeyboardTypeDefault;
    _returnKeyType = UIReturnKeyDone;
    _secureTextEntry = NO;
  }

  return self;
}

- (void)dealloc {
  [_text release];
  [_markedText release];
  [_markedTextRange release];
  [_selectedTextRange release];
  [_tokenizer release];
  [super dealloc];
}

- (void)setTextInputClient:(int)client {
  _textInputClient = client;
}

- (void)setTextInputState:(NSDictionary*)state {
  NSString* newText = state[@"text"];
  BOOL textChanged = ![self.text isEqualToString:newText];
  if (textChanged) {
    [self.inputDelegate textWillChange:self];
    [self.text setString:newText];
  }

  NSInteger selectionBase = [state[@"selectionBase"] intValue];
  NSInteger selectionExtent = [state[@"selectionExtent"] intValue];
  NSRange selectedRange = [self clampSelection:NSMakeRange(MIN(selectionBase, selectionExtent),
                                                           ABS(selectionBase - selectionExtent))
                                       forText:self.text];
  NSRange oldSelectedRange = [(FlutterTextRange*)self.selectedTextRange range];
  if (selectedRange.location != oldSelectedRange.location ||
      selectedRange.length != oldSelectedRange.length) {
    [self.inputDelegate selectionWillChange:self];
    [self setSelectedTextRange:[FlutterTextRange rangeWithNSRange:selectedRange]
            updateEditingState:NO];
    _selectionAffinity = _kTextAffinityDownstream;
    if ([state[@"selectionAffinity"] isEqualToString:@(_kTextAffinityUpstream)])
      _selectionAffinity = _kTextAffinityUpstream;
    [self.inputDelegate selectionDidChange:self];
  }

  NSInteger composingBase = [state[@"composingBase"] intValue];
  NSInteger composingExtent = [state[@"composingExtent"] intValue];
  NSRange composingRange = [self clampSelection:NSMakeRange(MIN(composingBase, composingExtent),
                                                            ABS(composingBase - composingExtent))
                                        forText:self.text];
  self.markedTextRange =
      composingRange.length > 0 ? [FlutterTextRange rangeWithNSRange:composingRange] : nil;

  if (textChanged) {
    [self.inputDelegate textDidChange:self];

    // For consistency with Android behavior, send an update to the framework.
    [self updateEditingState];
  }
}

- (NSRange)clampSelection:(NSRange)range forText:(NSString*)text {
  int start = MIN(MAX(range.location, 0), text.length);
  int length = MIN(range.length, text.length - start);
  return NSMakeRange(start, length);
}

#pragma mark - UIResponder Overrides

- (BOOL)canBecomeFirstResponder {
  return YES;
}

#pragma mark - UITextInput Overrides

- (id<UITextInputTokenizer>)tokenizer {
  if (_tokenizer == nil) {
    _tokenizer = [[UITextInputStringTokenizer alloc] initWithTextInput:self];
  }
  return _tokenizer;
}

- (UITextRange*)selectedTextRange {
  return [[_selectedTextRange copy] autorelease];
}

- (void)setSelectedTextRange:(UITextRange*)selectedTextRange {
  [self setSelectedTextRange:selectedTextRange updateEditingState:YES];
}

- (void)setSelectedTextRange:(UITextRange*)selectedTextRange updateEditingState:(BOOL)update {
  if (_selectedTextRange != selectedTextRange) {
    UITextRange* oldSelectedRange = _selectedTextRange;
    _selectedTextRange = [selectedTextRange copy];
    [oldSelectedRange release];

    if (update)
      [self updateEditingState];
  }
}

- (NSString*)textInRange:(UITextRange*)range {
  NSRange textRange = ((FlutterTextRange*)range).range;
  return [self.text substringWithRange:textRange];
}

- (void)replaceRange:(UITextRange*)range withText:(NSString*)text {
  NSRange replaceRange = ((FlutterTextRange*)range).range;
  NSRange selectedRange = _selectedTextRange.range;

  // Adjust the text selection:
  // * reduce the length by the intersection length
  // * adjust the location by newLength - oldLength + intersectionLength
  NSRange intersectionRange = NSIntersectionRange(replaceRange, selectedRange);
  if (replaceRange.location <= selectedRange.location)
    selectedRange.location += text.length - replaceRange.length;
  if (intersectionRange.location != NSNotFound) {
    selectedRange.location += intersectionRange.length;
    selectedRange.length -= intersectionRange.length;
  }

  [self.text replaceCharactersInRange:[self clampSelection:replaceRange forText:self.text]
                           withString:text];
  [self setSelectedTextRange:[FlutterTextRange rangeWithNSRange:[self clampSelection:selectedRange
                                                                             forText:self.text]]
          updateEditingState:NO];

  [self updateEditingState];
}

- (BOOL)shouldChangeTextInRange:(UITextRange*)range replacementText:(NSString*)text {
  if (self.returnKeyType == UIReturnKeyDone && [text isEqualToString:@"\n"]) {
    [self resignFirstResponder];
    [self removeFromSuperview];
    [_textInputDelegate performAction:FlutterTextInputActionDone withClient:_textInputClient];
    return NO;
  }
  if (self.returnKeyType == UIReturnKeyDefault && [text isEqualToString:@"\n"])
    [_textInputDelegate performAction:FlutterTextInputActionNewline withClient:_textInputClient];
  return YES;
}

- (void)setMarkedText:(NSString*)markedText selectedRange:(NSRange)markedSelectedRange {
  NSRange selectedRange = _selectedTextRange.range;
  NSRange markedTextRange = ((FlutterTextRange*)self.markedTextRange).range;

  if (markedText == nil)
    markedText = @"";

  if (markedTextRange.length > 0) {
    // Replace text in the marked range with the new text.
    [self replaceRange:self.markedTextRange withText:markedText];
    markedTextRange.length = markedText.length;
  } else {
    // Replace text in the selected range with the new text.
    [self replaceRange:_selectedTextRange withText:markedText];
    markedTextRange = NSMakeRange(selectedRange.location, markedText.length);
  }

  self.markedTextRange =
      markedTextRange.length > 0 ? [FlutterTextRange rangeWithNSRange:markedTextRange] : nil;

  NSUInteger selectionLocation = markedSelectedRange.location + markedTextRange.location;
  selectedRange = NSMakeRange(selectionLocation, markedSelectedRange.length);
  [self setSelectedTextRange:[FlutterTextRange rangeWithNSRange:[self clampSelection:selectedRange
                                                                             forText:self.text]]
          updateEditingState:YES];
}

- (void)unmarkText {
  self.markedTextRange = nil;
  [self updateEditingState];
}

- (UITextRange*)textRangeFromPosition:(UITextPosition*)fromPosition
                           toPosition:(UITextPosition*)toPosition {
  NSUInteger fromIndex = ((FlutterTextPosition*)fromPosition).index;
  NSUInteger toIndex = ((FlutterTextPosition*)toPosition).index;
  return [FlutterTextRange rangeWithNSRange:NSMakeRange(fromIndex, toIndex - fromIndex)];
}

/** Returns the range of the character sequence at the specified index in the
 * text. */
- (NSRange)rangeForCharacterAtIndex:(NSUInteger)index {
  if (index < self.text.length)
    return [self.text rangeOfComposedCharacterSequenceAtIndex:index];
  return NSMakeRange(index, 0);
}

- (NSUInteger)decrementOffsetPosition:(NSUInteger)position {
  return [self rangeForCharacterAtIndex:MAX(0, position - 1)].location;
}

- (NSUInteger)incrementOffsetPosition:(NSUInteger)position {
  NSRange charRange = [self rangeForCharacterAtIndex:position];
  return MIN(position + charRange.length, self.text.length);
}

- (UITextPosition*)positionFromPosition:(UITextPosition*)position offset:(NSInteger)offset {
  NSUInteger offsetPosition = ((FlutterTextPosition*)position).index;
  if (offset >= 0) {
    for (NSInteger i = 0; i < offset && offsetPosition < self.text.length; ++i)
      offsetPosition = [self incrementOffsetPosition:offsetPosition];
  } else {
    for (NSInteger i = 0; i < ABS(offset) && offsetPosition > 0; ++i)
      offsetPosition = [self decrementOffsetPosition:offsetPosition];
  }
  return [FlutterTextPosition positionWithIndex:offsetPosition];
}

- (UITextPosition*)positionFromPosition:(UITextPosition*)position
                            inDirection:(UITextLayoutDirection)direction
                                 offset:(NSInteger)offset {
  // TODO(cbracken) Add RTL handling.
  switch (direction) {
    case UITextLayoutDirectionLeft:
    case UITextLayoutDirectionUp:
      return [self positionFromPosition:position offset:offset * -1];
    case UITextLayoutDirectionRight:
    case UITextLayoutDirectionDown:
      return [self positionFromPosition:position offset:1];
  }
}

- (UITextPosition*)beginningOfDocument {
  return [FlutterTextPosition positionWithIndex:0];
}

- (UITextPosition*)endOfDocument {
  return [FlutterTextPosition positionWithIndex:self.text.length];
}

- (NSComparisonResult)comparePosition:(UITextPosition*)position toPosition:(UITextPosition*)other {
  NSUInteger positionIndex = ((FlutterTextPosition*)position).index;
  NSUInteger otherIndex = ((FlutterTextPosition*)other).index;
  if (positionIndex < otherIndex)
    return NSOrderedAscending;
  if (positionIndex > otherIndex)
    return NSOrderedDescending;
  return NSOrderedSame;
}

- (NSInteger)offsetFromPosition:(UITextPosition*)from toPosition:(UITextPosition*)toPosition {
  return ((FlutterTextPosition*)toPosition).index - ((FlutterTextPosition*)from).index;
}

- (UITextPosition*)positionWithinRange:(UITextRange*)range
                   farthestInDirection:(UITextLayoutDirection)direction {
  NSUInteger index;
  switch (direction) {
    case UITextLayoutDirectionLeft:
    case UITextLayoutDirectionUp:
      index = ((FlutterTextPosition*)range.start).index;
      break;
    case UITextLayoutDirectionRight:
    case UITextLayoutDirectionDown:
      index = ((FlutterTextPosition*)range.end).index;
      break;
  }
  return [FlutterTextPosition positionWithIndex:index];
}

- (UITextRange*)characterRangeByExtendingPosition:(UITextPosition*)position
                                      inDirection:(UITextLayoutDirection)direction {
  NSUInteger positionIndex = ((FlutterTextPosition*)position).index;
  NSUInteger startIndex;
  NSUInteger endIndex;
  switch (direction) {
    case UITextLayoutDirectionLeft:
    case UITextLayoutDirectionUp:
      startIndex = [self decrementOffsetPosition:positionIndex];
      endIndex = positionIndex;
      break;
    case UITextLayoutDirectionRight:
    case UITextLayoutDirectionDown:
      startIndex = positionIndex;
      endIndex = [self incrementOffsetPosition:positionIndex];
      break;
  }
  return [FlutterTextRange rangeWithNSRange:NSMakeRange(startIndex, endIndex - startIndex)];
}

#pragma mark - UITextInput text direction handling

- (UITextWritingDirection)baseWritingDirectionForPosition:(UITextPosition*)position
                                              inDirection:(UITextStorageDirection)direction {
  // TODO(cbracken) Add RTL handling.
  return UITextWritingDirectionNatural;
}

- (void)setBaseWritingDirection:(UITextWritingDirection)writingDirection
                       forRange:(UITextRange*)range {
  // TODO(cbracken) Add RTL handling.
}

#pragma mark - UITextInput cursor, selection rect handling

// The following methods are required to support force-touch cursor positioning
// and to position the
// candidates view for multi-stage input methods (e.g., Japanese) when using a
// physical keyboard.

- (CGRect)firstRectForRange:(UITextRange*)range {
  // TODO(cbracken) Implement.
  return CGRectZero;
}

- (CGRect)caretRectForPosition:(UITextPosition*)position {
  // TODO(cbracken) Implement.
  return CGRectZero;
}

- (UITextPosition*)closestPositionToPoint:(CGPoint)point {
  // TODO(cbracken) Implement.
  NSUInteger currentIndex = ((FlutterTextPosition*)_selectedTextRange.start).index;
  return [FlutterTextPosition positionWithIndex:currentIndex];
}

- (NSArray*)selectionRectsForRange:(UITextRange*)range {
  // TODO(cbracken) Implement.
  return @[];
}

- (UITextPosition*)closestPositionToPoint:(CGPoint)point withinRange:(UITextRange*)range {
  // TODO(cbracken) Implement.
  return range.start;
}

- (UITextRange*)characterRangeAtPoint:(CGPoint)point {
  // TODO(cbracken) Implement.
  NSUInteger currentIndex = ((FlutterTextPosition*)_selectedTextRange.start).index;
  return [FlutterTextRange rangeWithNSRange:[self rangeForCharacterAtIndex:currentIndex]];
}

#pragma mark - UIKeyInput Overrides

- (void)updateEditingState {
  NSUInteger selectionBase = ((FlutterTextPosition*)_selectedTextRange.start).index;
  NSUInteger selectionExtent = ((FlutterTextPosition*)_selectedTextRange.end).index;

  NSUInteger composingBase = 0;
  NSUInteger composingExtent = 0;
  if (self.markedTextRange != nil) {
    composingBase = ((FlutterTextPosition*)self.markedTextRange.start).index;
    composingExtent = ((FlutterTextPosition*)self.markedTextRange.end).index;
  }
  [_textInputDelegate updateEditingClient:_textInputClient
                                withState:@{
                                  @"selectionBase" : @(selectionBase),
                                  @"selectionExtent" : @(selectionExtent),
                                  @"selectionAffinity" : @(_selectionAffinity),
                                  @"selectionIsDirectional" : @(false),
                                  @"composingBase" : @(composingBase),
                                  @"composingExtent" : @(composingExtent),
                                  @"text" : [NSString stringWithString:self.text],
                                }];
}

- (BOOL)hasText {
  return self.text.length > 0;
}

- (void)insertText:(NSString*)text {
  _selectionAffinity = _kTextAffinityUpstream;
  [self replaceRange:_selectedTextRange withText:text];
}

- (void)deleteBackward {
  _selectionAffinity = _kTextAffinityDownstream;
  if (!_selectedTextRange.isEmpty)
    [self replaceRange:_selectedTextRange withText:@""];
}

@end

/**
 * Hides `FlutterTextInputView` from iOS accessibility system so it
 * does not show up twice, once where it is in the `UIView` hierarchy,
 * and a second time as part of the `SemanticsObject` hierarchy.
 */
@interface FlutterTextInputViewAccessibilityHider : UIView {
}

@end

@implementation FlutterTextInputViewAccessibilityHider {
}

- (BOOL)accessibilityElementsHidden {
  return YES;
}

@end

@implementation FlutterTextInputPlugin {
  FlutterTextInputView* _view;
  FlutterTextInputViewAccessibilityHider* _inputHider;
}

@synthesize textInputDelegate = _textInputDelegate;

- (instancetype)init {
  self = [super init];

  if (self) {
    _view = [[FlutterTextInputView alloc] init];
    _inputHider = [[FlutterTextInputViewAccessibilityHider alloc] init];
  }

  return self;
}

- (void)dealloc {
  [self hideTextInput];
  [_view release];
  [_inputHider release];

  [super dealloc];
}

- (UIView<UITextInput>*)textInputView {
  return _view;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString* method = call.method;
  id args = call.arguments;
  if ([method isEqualToString:@"TextInput.show"]) {
    [self showTextInput];
    result(nil);
  } else if ([method isEqualToString:@"TextInput.hide"]) {
    [self hideTextInput];
    result(nil);
  } else if ([method isEqualToString:@"TextInput.setClient"]) {
    [self setTextInputClient:[args[0] intValue] withConfiguration:args[1]];
    result(nil);
  } else if ([method isEqualToString:@"TextInput.setEditingState"]) {
    [self setTextInputEditingState:args];
    result(nil);
  } else if ([method isEqualToString:@"TextInput.clearClient"]) {
    [self clearTextInputClient];
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)showTextInput {
  NSAssert([UIApplication sharedApplication].keyWindow != nullptr,
           @"The application must have a key window since the keyboard client "
           @"must be part of the responder chain to function");
  _view.textInputDelegate = _textInputDelegate;
  [_inputHider addSubview:_view];
  [[UIApplication sharedApplication].keyWindow addSubview:_inputHider];
  [_view becomeFirstResponder];
}

- (void)hideTextInput {
  [_view resignFirstResponder];
  [_view removeFromSuperview];
  [_inputHider removeFromSuperview];
}

- (void)setTextInputClient:(int)client withConfiguration:(NSDictionary*)configuration {
  NSDictionary* inputType = configuration[@"inputType"];
  _view.keyboardType = ToUIKeyboardType(inputType);
  _view.returnKeyType = ToUIReturnKeyType(inputType[@"name"]);
  _view.autocapitalizationType = ToUITextAutocapitalizationType(inputType[@"name"]);
  _view.secureTextEntry = [configuration[@"obscureText"] boolValue];
  NSString* autocorrect = configuration[@"autocorrect"];
  _view.autocorrectionType = autocorrect && ![autocorrect boolValue]
                                 ? UITextAutocorrectionTypeNo
                                 : UITextAutocorrectionTypeDefault;
  [_view setTextInputClient:client];
  [_view reloadInputViews];
}

- (void)setTextInputEditingState:(NSDictionary*)state {
  [_view setTextInputState:state];
}

- (void)clearTextInputClient {
  [_view setTextInputClient:0];
}

@end
