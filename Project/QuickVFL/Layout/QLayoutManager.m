//
//  QLayoutManager.m
//  LibSourceUser
//
//  Created by 苏第 on 17/11/5.
//  Copyright © 2017年 Su Di. All rights reserved.
//

#import "QLayoutManager.h"
#import "QLayoutResult.h"
#import "UIView+constraint.h"
#import "UIScrollView+constraint.h"
#import "QParseException.h"
#import "QViewProperty.h"
#import "QStayShapedOption.h"
#import "QEqualOption.h"
#import "QAlignOption.h"
#import "QLayoutException.h"
#import "QAutoConfig.h"

#import <objc/runtime.h>

QLayoutMode layoutMode = QLayoutModeVerbose;

static NSLock* managerLock;
@implementation QLayoutManager
#pragma mark - private methods
+(NSMutableArray<QLayoutManager*>*)managerPool{
    static dispatch_once_t onceToken;
    static NSMutableArray* arrayManagers;
    dispatch_once(&onceToken, ^{
        arrayManagers = [[NSMutableArray alloc] init];
        managerLock = [[NSLock alloc] init];
    });
    
    return arrayManagers;
}

+(QLayoutManager*)dequeueLayoutManager{
    NSMutableArray* managers = [self managerPool];
    
    [managerLock lock];
    
    QLayoutManager* result = nil;
    result = [managers lastObject];
    if(result == nil){
        result = [[QLayoutManager alloc] init];
    } else {
        [managers removeObject:result];
    }
    
    [managerLock unlock];
    
    return result;
}

+(void)enqueueLayoutManager:(QLayoutManager*)manager{
    NSMutableArray* managers = [self managerPool];
    
    [managerLock lock];
    [managers addObject:manager];
//    NSLog(@"Manager count in pool: %d", managers.count);
    [managerLock unlock];
}

+(NSDictionary*)fetchIvarInformationForClass:(Class)targetClass{
    NSMutableDictionary* result = [[NSMutableDictionary alloc] init];
    
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(targetClass, &count);
    NSCharacterSet* replaceSet = [NSCharacterSet characterSetWithCharactersInString:@"@\""];
    
    NSString *key, *type;
    Ivar ivar;
    for (int i = 0; i<count; i++) {
        // 取出成员变量
        ivar = *(ivars + i);
        key = [NSString stringWithUTF8String:ivar_getName(ivar)];
        type = [NSString stringWithUTF8String:ivar_getTypeEncoding(ivar)];
        type = [type stringByTrimmingCharactersInSet:replaceSet];
        [result setValue:type forKey:key];
    }
    
    free(ivars);
    
    return result;
}

+(QViewProperty*)parseLayoutContent:(NSString*)content{
    NSError* error;
    NSString* trimedText = [content stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    
    NSDictionary* dict = [NSJSONSerialization JSONObjectWithData:[trimedText dataUsingEncoding:NSUTF8StringEncoding]
                                                         options:0
                                                           error:&error];
    if(error){
        [QParseException throwExceptionForReason:@"Failed while parsing layout file: %@", error];
        return nil;
    }
    
    if(![dict isKindOfClass:[NSDictionary class]]){
        [QParseException throwExceptionForReason:@"Top of the layout file must be a dictionary."];
        return nil;
    }
    
    return [self parseViewPropertyForLayout:dict];
}

+(Class)parseClassName:(NSString*)className{
    Class targetClass = NSClassFromString(className);
    if(targetClass == nil){
        [QParseException throwExceptionForReason:@"Unknown Class: %@.", className];
        return nil;
    }
    
    if(![targetClass isSubclassOfClass:[UIView class]]){
        [QParseException throwExceptionForReason:@"%@ is not a subclass of UIView.", className];
        return nil;
    }
    
    return targetClass;
}

+(QViewProperty*)parseViewPropertyForLayout:(NSDictionary*)layout{
    NSMutableArray* subViewKeys = [NSMutableArray arrayWithArray:layout.allKeys];
    NSMutableArray* optionKeys = [[NSMutableArray alloc] init];
    
    for (NSString* key in layout.allKeys) {
        if ([key hasPrefix:@":"]) {
            [subViewKeys removeObject:key];
            [optionKeys addObject:key];
        }
    }
    
    QViewProperty* property = [[QViewProperty alloc] init];
    
    // handle subviews
    if(subViewKeys.count > 0){
        NSMutableArray* subviewsProperty = [[NSMutableArray alloc] init];
        
        Class stringClass = [NSString class];
        Class dictClass = [NSDictionary class];
        id value;
        for (NSString* viewName in subViewKeys) {
            value = [layout objectForKey:viewName];
            if([value isKindOfClass:stringClass]){
                Class targetClass = [self parseClassName:value];
                [subviewsProperty addObject:[QViewProperty propertyWithViewName:viewName class:targetClass]];
            } else if([value isKindOfClass:dictClass]){
                QViewProperty* nestedProperty = [self parseViewPropertyForLayout:value];
                nestedProperty.name = viewName;
                [subviewsProperty addObject:nestedProperty];
            }
        }
        
        property.subviewsProperty = subviewsProperty;
    }
    
    // handle options
    for (NSString* key in optionKeys) {
        [property parseOptionKey:key value:[layout objectForKey:key]];
    }
    
    // other checkings
    if(property.isViewContainer && property.viewClass == nil){
        property.viewClass = [UIView class];
    }
    
    if(!property.isViewContainer && property.isScrollEnabled){
        [QParseException throwExceptionForReason:@"Scroll option is for view container only."];
        return nil;
    }
    
    return property;
}

-(UIScrollView*)handleScrollOption:(QOrientationOption)option withEntrance:(UIView*)entrance{
    UIScrollView* scrollView = QVIEW(entrance, UIScrollView);
    [entrance q_addConstraintsByText:@"H:|[scrollView]|; V:|[scrollView]|;"
                       involvedViews:NSDictionaryOfVariableBindings(scrollView)];
    switch (option) {
        case QOrientationHorizontal:
            [scrollView q_prepareContentViewForOrientation:QScrollOrientationHorizontal];
            break;
        case QOrientationVertical:
            [scrollView q_prepareContentViewForOrientation:QScrollOrientationVertical];
            break;
        default:
            [QParseException throwExceptionWithUserInfo:@{@"entrance": entrance}
                                                 reason:@"Bad scroll option for entrance" ];
            break;
    }
    
    return scrollView;
}

-(void)creatingViewsForLayout:(QViewProperty*)propertyTree
                     entrance:(UIView*)entrance
                    madeViews:(NSMutableDictionary*)views{
    UIView* realEntrance = entrance;
    
    // handling scroll view
    if(propertyTree.isScrollEnabled){
        UIScrollView* scrollView = [self handleScrollOption:propertyTree.scrollOrientation withEntrance:entrance];
        propertyTree.scrollViewShadow = scrollView;
        [views setObject:scrollView forKey:propertyTree.scrollViewName];
        realEntrance = scrollView.q_contentView;
    }
    
    UIView* madeView;
    for (QViewProperty* property in propertyTree.subviewsProperty) {
        madeView = QVIEW(realEntrance, property.viewClass);
        
        [views setObject:madeView forKey:property.name];
        if(property.isViewContainer){
            [self creatingViewsForLayout:property entrance:madeView madeViews:views];
        }
    }
}

-(void)setupViewsForLayout:(QViewProperty*)propertyTree
                  entrance:(UIView*)entrance
                 madeViews:(NSMutableDictionary*)views
                    holder:(id)holder{
    UIView* realEntrance = entrance;
    if(propertyTree.isScrollEnabled){
        UIScrollView* scrollView = (UIScrollView*)propertyTree.scrollViewShadow;
        realEntrance = scrollView.q_contentView;
    }
    
    [realEntrance q_configureWithData:propertyTree.viewData holder:holder];
    
    // subviews
    UIView* madeView;
    for (QViewProperty* property in propertyTree.subviewsProperty) {
        madeView = [views objectForKey:property.name];
        if(property.isViewContainer){
            [self setupViewsForLayout:property entrance:madeView madeViews:views holder:holder];
        } else {
            [madeView q_configureWithData:property.viewData holder:holder];
        }
    }
}

-(void)attachingViewDataForLayout:(QViewProperty*)propertyTree
                        viewsData:(NSMutableDictionary*)data{
    if(propertyTree.viewData != nil){
        [data setObject:propertyTree.viewData forKey:propertyTree.name];
    }
    
    for (QViewProperty* property in propertyTree.subviewsProperty) {
        [self attachingViewDataForLayout:property viewsData:data];
    }
}

-(void)addingConstraintsForLayout:(QViewProperty*)propertyTree
                         entrance:(UIView*)entrance
                        madeViews:(NSDictionary*)views{
    UIView* realEntrance = entrance;
    
    // handling stay shaped options
    for (QStayShapedOption* stayOption in propertyTree.arrayStayShapeOptions) {
        UILayoutConstraintAxis axis = stayOption.orientation == QOrientationHorizontal ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
        if(stayOption.isCompressed){
            [realEntrance setContentCompressionResistancePriority:stayOption.priority forAxis:axis];
        } else {
            [realEntrance setContentHuggingPriority:stayOption.priority forAxis:axis];
        }
    }
    
    // handling equal options
    for(QEqualOption* equalOption in propertyTree.arrayEqualOptions) {
        UIView* targetView = [views objectForKey:equalOption.targetViewName];
        if(targetView == nil){
            [QParseException throwExceptionForReason:@"Can't find target view named %@", equalOption.targetViewName];
            continue;
        }
        
        [QEqualOption equalView:realEntrance
                   forAttrubute:equalOption.firstAttribute
                    toOtherView:targetView
                   forAttrubute:equalOption.secondAttribute
                     multiplier:equalOption.multiplier];
    }
    
    if(propertyTree.isScrollEnabled){
        realEntrance = ((UIScrollView*)propertyTree.scrollViewShadow).q_contentView;
    }
    
    if(propertyTree.VFLText.length > 0){
        [realEntrance q_addConstraintsByText:propertyTree.VFLText
                               involvedViews:views];
    }
    
    // handle align option
    if(propertyTree.arrayAlighOptions.count > 0){
        [QAlignOption alignViews:views
                     withOptions:propertyTree.arrayAlighOptions
                    withEntrance:realEntrance];
    }
    
    for (QViewProperty* property in propertyTree.subviewsProperty) {
        [self addingConstraintsForLayout:property
                                entrance:[views objectForKey:property.name]
                               madeViews:views];
    }
}

-(void)mappingViews:(NSDictionary*)createdViews forHolder:(id)holder{
    NSDictionary* ivarInfo = [QLayoutManager fetchIvarInformationForClass:[holder class]];
    
    NSString* name;
    UIView* targetView;
    for (NSString* viewName in createdViews.allKeys) {
        targetView = [createdViews objectForKey:viewName];
        
        name = viewName;
        if([ivarInfo objectForKey:name] == nil){
            name = [NSString stringWithFormat:@"_%@", viewName];
        }
        
        if([ivarInfo objectForKey:name] == nil){
            if(![viewName hasSuffix:@"_"]){
                [QParseException throwExceptionForReason:@"View named %@ is claimed to be mapped. But failed to be done. Have you declared any ivar for it?", viewName];
            }
        } else {
            if([holder valueForKey:name]){
                [QLayoutException throwExceptionForReason:@"View named %@ is supposed to be nil before mapping. But now it is not. Quit in case of mis-mapping.", name];
            }
            
            Class ivarClass = [QLayoutManager parseClassName:[ivarInfo objectForKey:name]];
            
            if(![[targetView class] isSubclassOfClass:ivarClass]){
                [QLayoutException throwExceptionForReason:@"View named %@ is supposed to be an instance of class or subclass %@. But now it is instance of %@. Quit in case of mis-mapping.",
                        name, [ivarInfo objectForKey:name], NSStringFromClass([targetView class])];
            }
            
            [holder setValue:targetView forKey:name];
        }
    }
}

-(QLayoutResult*) _layoutForContent:(NSString*)content
                           entrance:(UIView*)entrance
                             holder:(id)holder{
    QLayoutResult* result = [[QLayoutResult alloc] init];
    
    if(entrance == nil){
        [QLayoutException throwExceptionForReason:@"Entrance of layout tree is required."];
        return nil;
    }
    
    if(holder == nil){
        [QLayoutException throwExceptionForReason:@"Holder of the layout tree is required."];
        return nil;
    }
    
    QViewProperty* property = [QLayoutManager parseLayoutContent:content];
    NSMutableDictionary* madeViews = [[NSMutableDictionary alloc] init];
    [self creatingViewsForLayout:property
                        entrance:entrance
                       madeViews:madeViews];
    [self addingConstraintsForLayout:property
                            entrance:entrance
                           madeViews:madeViews];
    [self setupViewsForLayout:property
                     entrance:entrance
                    madeViews:madeViews
                       holder:holder];
    
    [self mappingViews:madeViews forHolder:holder];
    
    result.createdViews = [madeViews copy];
    
    NSMutableDictionary* viewsData = [[NSMutableDictionary alloc] init];
    [self attachingViewDataForLayout:property viewsData:viewsData];
    result.viewsData = [viewsData copy];
    return result;
}

+(NSString*)contentForFilePath:(NSString*)filePath{
    NSError* error;
    NSString* jsonText = [NSString stringWithContentsOfFile:filePath
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
    if(error){
        [QParseException throwExceptionForReason:@"Failed while reading layout file: %@", error];
        return nil;
    }
    
    return jsonText;
}

#pragma mark - public methods
+(QLayoutResult*) layoutForContent:(NSString*)content
                          entrance:(UIView*)entrance
                            holder:(id)holder{
    QLayoutManager* manager = [self dequeueLayoutManager];
    QLayoutResult* result = [manager _layoutForContent:content
                                              entrance:entrance
                                                holder:holder];
    [self enqueueLayoutManager:manager];
    return result;
}

+(QLayoutResult*) layoutForFilePath:(NSString*)filePath
                            entrance:(UIView*)entrance
                              holder:(id)holder{
    return [self layoutForContent:[self contentForFilePath:filePath]
                  entrance:entrance
                    holder:holder];
}

+(QLayoutResult*) layoutForFileName:(NSString*)fileName
                           entrance:(UIView*)entrance
                             holder:(id)holder{
    NSString* filePath = [[NSBundle mainBundle] pathForResource:fileName ofType:nil];
    return [self layoutForFilePath:filePath entrance:entrance holder:holder];
}

+(void)setupLayoutMode:(QLayoutMode)mode{
    layoutMode = mode;
}

+(QLayoutMode)layoutMode{
    return layoutMode;
}
@end
