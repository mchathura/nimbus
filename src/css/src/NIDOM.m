//
// Copyright 2011 Jeff Verkoeyen
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "NIDOM.h"

#import "NIStylesheet.h"
#import "NIStyleable.h"
#import "NimbusCore.h"
#import "NICSSRuleset.h"
#import <objc/runtime.h>

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "Nimbus requires ARC support."
#endif

static const int numPreallocatedRulesets = 1000;
static int refreshDepth = 0;

@interface NICSSRulesetAllocator : NSObject {
    int _rulesetIndex;
    NICSSRuleset* _preallocatedRulesets[numPreallocatedRulesets];
}

+ (instancetype)sharedAllocator;
- (NICSSRuleset*)getRuleset;
- (void)reset;

@end

@implementation NICSSRulesetAllocator

////////////////////////////////////////////////////////////////////////////////////////////////////
+ (NICSSRulesetAllocator*)sharedAllocator {
    static dispatch_once_t pred;
    static NICSSRulesetAllocator* shared = nil;
    dispatch_once(&pred, ^{ shared = [[self alloc] init]; });
    return shared;
}

////////////////////////////////////////////////////////////////////////////////////////////////////
- (id)init {
    if ((self = [super init])) {
        for (int i = 0; i < numPreallocatedRulesets; i++) {
            _preallocatedRulesets[i] = [[[NIStylesheet rulesetClass] alloc] init];
        }
        _rulesetIndex = 0;

        NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
        [nc addObserver: self
               selector: @selector(didReceiveMemoryWarning:)
                   name: UIApplicationDidReceiveMemoryWarningNotification
                 object: nil];
    }

    return self;
}

////////////////////////////////////////////////////////////////////////////////////////////////////
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)didReceiveMemoryWarning:(void*)object {
    for (int i = 0; i < numPreallocatedRulesets; i++) {
        //[_preallocatedRulesets[i] reduceMemory];
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
-(NICSSRuleset *)getRuleset {
    NICSSRuleset *r;
    if (_rulesetIndex < numPreallocatedRulesets) {
        r = _preallocatedRulesets[_rulesetIndex];
    } else {
        r = [[NIStylesheet rulesetClass] alloc];
        if ([r respondsToSelector:@selector(initAndRegisterForMemoryWarnings)]) {
            r = [r initAndRegisterForMemoryWarnings];
        } else {
            r = [r init];
        }
    }

    [r reset];
    _rulesetIndex++;
    return r;
}

////////////////////////////////////////////////////////////////////////////////////////////////////
- (void)reset {
    _rulesetIndex = 0;
}

@end


@interface NIDOM ()
@property (nonatomic,strong) NSArray* stylesheets;
@property (nonatomic,strong) NSMutableArray* registeredViews;
@property (nonatomic,strong) NSMutableDictionary* idToViewMap;
@property (nonatomic,strong) NSMutableSet *refreshedViews;
@end

///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
@implementation NIDOM


///////////////////////////////////////////////////////////////////////////////////////////////////
+ (id)domWithStylesheet:(NIStylesheet *)stylesheet {
  return [[self alloc] initWithStylesheets:@[stylesheet]];
}

+ (id)domWithStylesheets:(NSArray *)stylesheets {
  return [[self alloc] initWithStylesheets:stylesheets];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (id)initWithStylesheets:(NSArray *)stylesheets {
  if ((self = [super init])) {
    _stylesheets = [stylesheets copy];
    _registeredViews = [NSMutableArray array];
  }
  return self;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)dealloc {
  [self unregisterAllViews];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Styling Views

///////////////////////////////////////////////////////////////////////////////////////////////////
- (NSString *)infoForView:(UIView *)view {
  NSArray *selectors = objc_getAssociatedObject(view, &niDOM_ViewSelectorsKey);

  NSMutableString *styleDescription = [NSMutableString new];
  // Add classes and ids to the style description
  [selectors enumerateObjectsUsingBlock:^(NSString *sel, NSUInteger idx, BOOL *stop) {
    [styleDescription appendFormat:@"%@, ", sel];
  }];
  [styleDescription appendString:@"\n"];

  NICSSRuleset *ruleset = [[NICSSRulesetAllocator sharedAllocator] getRuleset];
  for (NIStylesheet *stylesheet in self.stylesheets) {
    NSString *selectorDescription = [stylesheet addStylesForView:view withSelectors:selectors toRuleset:ruleset inDOM:self shouldReturnDescription:YES];
    // Add matching selectors per stylesheet to the style description
    [styleDescription appendFormat:@"Selectors from <%@> ::\n", stylesheet.filePath];
    [styleDescription appendString:selectorDescription];
  }

  // Add composite ruleset to the style description
  [styleDescription appendFormat:@"Composite ruleset:\n"];
  [styleDescription appendFormat:@"%@", ruleset];

  return styleDescription;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)refreshStyleForView:(UIView *)view {
  NSArray *selectors = objc_getAssociatedObject(view, &niDOM_ViewSelectorsKey);
  NSArray *pseudoSelectors = objc_getAssociatedObject(view, &niDOM_ViewPseudoSelectorsKey);

  NICSSRuleset *ruleset = [[NICSSRulesetAllocator sharedAllocator] getRuleset];
  for (NIStylesheet *stylesheet in self.stylesheets) {
      [stylesheet addStylesForView:view withSelectors:selectors toRuleset:ruleset inDOM:self shouldReturnDescription:NO];
  }

  [self applyRuleSet:ruleset toView:view];

  for (NSString *pseudoSelector in pseudoSelectors) {
    if ([view respondsToSelector:@selector(applyStyleWithRuleSet:forPseudoClass:inDOM:)]) {
      NSRange r = [pseudoSelector rangeOfString:@":"];

      NICSSRuleset *ruleset = [[NICSSRulesetAllocator sharedAllocator] getRuleset];
      for (NIStylesheet *stylesheet in self.stylesheets) {
        [stylesheet addStylesForView:view withSelectors:@[pseudoSelector] toRuleset:ruleset inDOM:self shouldReturnDescription:NO];
      }
      [(id<NIStyleable>)view applyStyleWithRuleSet:ruleset
                                    forPseudoClass:[pseudoSelector substringFromIndex:r.location+1]
                                             inDOM:self];
    }
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)applyRuleSet:(NICSSRuleset *)ruleSet toView:(UIView *)view {
  if ([view respondsToSelector:@selector(applyStyleWithRuleSet:inDOM:)]) {
    [(id<NIStyleable>)view applyStyleWithRuleSet:ruleSet inDOM:self];
  }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public Methods

static char niDOM_ViewSelectorsKey = 0;
static char niDOM_ViewPseudoSelectorsKey = 1;
///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)registerSelector:(NSString *)selector withView:(UIView *)view {

  if ([selector rangeOfString:@":"].length) {
    NSMutableArray *pseudoSelectors = objc_getAssociatedObject(view, &niDOM_ViewPseudoSelectorsKey);
    if (!pseudoSelectors) {
      pseudoSelectors = [[NSMutableArray alloc] init];
      objc_setAssociatedObject(view, &niDOM_ViewPseudoSelectorsKey, pseudoSelectors, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [pseudoSelectors addObject:selector];
  } else {
    NSMutableArray *selectors = objc_getAssociatedObject(view, &niDOM_ViewSelectorsKey);
    if (!selectors) {
      selectors = [[NSMutableArray alloc] init];
      objc_setAssociatedObject(view, &niDOM_ViewSelectorsKey, selectors, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [selectors addObject:selector];
  }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)registerView:(UIView *)view {
  NIDASSERT(self.refreshedViews == nil); // You are already in the midst of a refresh. Don't do this.

  NSString* selector = NSStringFromClass([view class]);
  [self registerSelector:selector withView:view];
  
  NSArray *pseudos = nil;
  if ([view respondsToSelector:@selector(pseudoClasses)]) {
    pseudos = (NSArray*) [view performSelector:@selector(pseudoClasses)];
    if (pseudos) {
      for (NSString *ps in pseudos) {
        [self registerSelector:[selector stringByAppendingString:ps] withView:view];
      }
    }
  }
    
  [_registeredViews addObject:view];
  if ([view respondsToSelector:@selector(didRegisterInDOM:)]) {
    [((id<NIStyleable>)view) didRegisterInDOM:self];
  }
}

- (void)registerView:(UIView *)view withCSSClass:(NSString *)cssClass andId:(NSString *)viewId
{
  NIDASSERT(self.refreshedViews == nil); // You are already in the midst of a refresh. Don't do this.

  // These are basically the least specific selectors (by our simple rules), so this needs to get registered first
  [self registerView:view withCSSClass:cssClass];

  NSArray *pseudos = nil;
  if (viewId) {
    if (![viewId hasPrefix:@"#"]) { viewId = [@"#" stringByAppendingString:viewId]; }

    [self registerSelector:viewId withView:view];
    
    if ([view respondsToSelector:@selector(pseudoClasses)]) {
      pseudos = (NSArray*) [view performSelector:@selector(pseudoClasses)];
      if (pseudos) {
        for (NSString *ps in pseudos) {
          [self registerSelector:[viewId stringByAppendingString:ps] withView:view];
        }
      }
    }

    if (!_idToViewMap) {
      _idToViewMap = (__bridge_transfer NSMutableDictionary *)CFDictionaryCreateMutable(nil, 0, &kCFCopyStringDictionaryKeyCallBacks, nil);
    }
    [_idToViewMap setObject:view forKey:viewId.lowercaseString];
    
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)registerView:(UIView *)view withCSSClass:(NSString *)cssClass registerMainView: (BOOL) registerMainView
{
  if (registerMainView) {
    [self registerView:view];
  }
  
  if (cssClass) {
    [self addCssClass:cssClass toView:view];
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)registerView:(UIView *)view withCSSClass:(NSString *)cssClass {
  [self registerView:view withCSSClass:cssClass registerMainView:YES];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (BOOL)view: (UIView*) view hasShortSelector: (NSString*) shortSelector
{
  NSMutableArray *selectors = objc_getAssociatedObject(view, &niDOM_ViewSelectorsKey);
  if ([selectors containsObject:shortSelector]) {
    return YES;
  }

  NSMutableArray *pseudoSelectors = objc_getAssociatedObject(view, &niDOM_ViewPseudoSelectorsKey);
  return [pseudoSelectors containsObject:shortSelector];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)addCssClasses:(NSArray *)cssClasses toView:(UIView *)view {
  for (NSString *cssClass in cssClasses) {
    [self addCssClass:cssClass toView:view];
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
-(void)addCssClass:(NSString *)cssClass toView:(UIView *)view
{
  NSString *selector = cssClass;
  if (![selector hasPrefix:@"."]) {
    selector = [@"." stringByAppendingString:cssClass];
  }
  [self registerSelector:selector withView:view];
  
  // This registers both the UIKit class name and the css class name for this view
  // Now, we also want to register the 'state based' selectors. Fun.
  NSArray *pseudos = nil;
  if ([view respondsToSelector:@selector(pseudoClasses)]) {
    pseudos = (NSArray*) [view performSelector:@selector(pseudoClasses)];
    if (pseudos) {
      for (NSString *ps in pseudos) {
        [self registerSelector:[selector stringByAppendingString:ps] withView:view];
      }
    }
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
-(void)removeCssClass:(NSString *)cssClass fromView:(UIView *)view
{
  NSString* selector = [cssClass hasPrefix:@"."] ? cssClass : [@"." stringByAppendingString:cssClass];
  NSMutableArray *selectors = objc_getAssociatedObject(view, &niDOM_ViewSelectorsKey);
  if (selectors) {
    for (int i = ((int)selectors.count)-1; i >= 0; i--) {
      NSString *s = [selectors objectAtIndex:i];
      if ([s isEqualToString:selector]) {
        [selectors removeObjectAtIndex:i];
      }
    }
  }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)unregisterView:(UIView *)view {
  if (!view) return;
  [_registeredViews removeObject:view];
  NSArray *selectors = objc_getAssociatedObject(view, &niDOM_ViewSelectorsKey);
  if (selectors) {
    // Iterate over the selectors finding the id selector (if any) so we can
    // also remove it from the id map
    for (NSString *s in selectors) {
      if ([s characterAtIndex:0] == '#') {
        [_idToViewMap removeObjectForKey:s.lowercaseString];
      }
    }
  }
  objc_setAssociatedObject(view, &niDOM_ViewSelectorsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(view, &niDOM_ViewPseudoSelectorsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if ([view respondsToSelector:@selector(didUnregisterInDOM:)]) {
    [((id<NIStyleable>)view) didUnregisterInDOM:self];
  }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)unregisterAllViews {
  [_registeredViews enumerateObjectsUsingBlock:^(UIView *view, NSUInteger idx, BOOL *stop) {
    objc_setAssociatedObject(view, &niDOM_ViewSelectorsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &niDOM_ViewPseudoSelectorsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([view respondsToSelector:@selector(didUnregisterInDOM:)]) {
      [((id<NIStyleable>)view) didUnregisterInDOM:self];
    }
  }];
  [_registeredViews removeAllObjects];
  [_idToViewMap removeAllObjects];
}


///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)refresh {
  NIDASSERT(self.refreshedViews == nil); // You are already in the midst of a refresh. Don't do this.
  if (refreshDepth == 0) {
    [[NICSSRulesetAllocator sharedAllocator] reset];
  }
  refreshDepth++;
  self.refreshedViews = [[NSMutableSet alloc] initWithCapacity:_registeredViews.count+1];
  for (UIView* view in _registeredViews) {
    [self.refreshedViews addObject:view];
    [self refreshStyleForView:view];
  }
  self.refreshedViews = nil;
  refreshDepth--;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
- (void)refreshView:(UIView *)view {
  NIDASSERT(self.refreshedViews == nil); // You are already in the midst of a refresh. Don't do this.
  if (!view) {
      return;
  }
  if (refreshDepth == 0) {
    [[NICSSRulesetAllocator sharedAllocator] reset];
  }
  refreshDepth++;
  self.refreshedViews = [[NSMutableSet alloc] init];
  [self.refreshedViews addObject:view];
  [self refreshStyleForView:view];
  self.refreshedViews = nil;
  refreshDepth--;
}

///////////////////////////////////////////////////////////////////////////////////////////////////
-(void)ensureViewHasBeenRefreshed:(UIView *)view {
  NIDASSERT(self.refreshedViews != nil); // You are calling this outside a refresh. Don't do this.
  if ([self.refreshedViews containsObject:view]) {
    return;
  }
  [self refreshStyleForView:view];
  [self.refreshedViews addObject:view];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
-(UIView *)viewById:(NSString *)viewId
{
  if (![viewId hasPrefix:@"#"]) { viewId = [@"#" stringByAppendingString:viewId]; }
  return [_idToViewMap objectForKey:viewId.lowercaseString];
}

///////////////////////////////////////////////////////////////////////////////////////////////////
-(BOOL)isRefreshing {
  return self.refreshedViews != nil;
}

@end
