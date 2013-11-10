//
//  OFPlugin.m
//  OFPlugin
//
//  Created by Adam on 2013-08-14.
//    Copyright (c) 2013 admsyn. All rights reserved.
//

#import "OFPlugin.h"
#import "OFAddon.h"
#import "OFAddonMenuItem.h"
#import <objc/objc-runtime.h>

@interface OFPlugin() {
	NSString * _addonsPath;
	NSMenu * _addonsListMenu;
	NSMenuItem * _addAddonItem;
}

@property (nonatomic, strong) NSBundle * bundle;

@end

@implementation OFPlugin

+ (void)pluginDidLoad:(NSBundle *)plugin
{
    static id sharedPlugin = nil;
    static dispatch_once_t onceToken;
    NSString * currentAppName = [[NSBundle mainBundle] infoDictionary][@"CFBundleName"];
    if ([currentAppName isEqual:@"Xcode"]) {
        dispatch_once(&onceToken, ^{
            sharedPlugin = [[self alloc] initWithBundle:plugin];
        });
    }
}

- (id)initWithBundle:(NSBundle *)plugin {
	
	if (self = [super init]) {
		self.bundle = plugin;
		[self generateMenu];
	}
	return self;
}

#pragma mark - Menu stuffs

- (void)generateMenu {
	NSMenuItem * ofMenuItem = [[NSMenuItem alloc] initWithTitle:@"openFrameworks" action:@selector(menuSelected:) keyEquivalent:@""];
	[ofMenuItem setTarget:self];
	
	NSMenu * topLevelMenu = [[NSMenu alloc] initWithTitle:@"OF"];
	[ofMenuItem setSubmenu:topLevelMenu];
	
	NSMenuItem * addonsPathItem = [topLevelMenu addItemWithTitle:@"Set addons path..." action:@selector(setAddonsPath:) keyEquivalent:@""];
	[addonsPathItem setTarget:self];
	[addonsPathItem setEnabled:YES];
	
	_addAddonItem = [topLevelMenu addItemWithTitle:@"Add addon" action:@selector(menuSelected:) keyEquivalent:@""];
	_addonsListMenu = [[NSMenu alloc] initWithTitle:@"addon-list"];
	[_addAddonItem setTarget:self];
	
	_addonsPath = [@"~/workspace/openFrameworks/addons/" stringByExpandingTildeInPath];
	[_addAddonItem setSubmenu:_addonsListMenu];
	[self scanAddons];
	
	NSUInteger menuIndex = [[NSApp mainMenu] indexOfItemWithTitle:@"Navigate"];
	[[NSApp mainMenu] insertItem:ofMenuItem atIndex:menuIndex > 0 ? menuIndex : 5];
	
}

- (void)menuSelected:(id)sender {
	
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
	return YES;
}

#pragma mark - Addons directory

- (void)scanAddons
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[_addonsListMenu removeAllItems];
		
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			NSArray * allAddons = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_addonsPath error:nil];
			
			dispatch_async(dispatch_get_main_queue(), ^{
				NSArray * sortedAddons = [allAddons sortedArrayUsingComparator:^NSComparisonResult(NSString * a, NSString * b) {
					return [a compare:b];
				}];
				
				for(NSString * addon in sortedAddons) {
					if([addon rangeOfString:@"ofx"].location != NSNotFound) {
						OFAddonMenuItem * addonItem = [[OFAddonMenuItem alloc] initWithTitle:addon
																					  action:@selector(addAddonForMenuItem:)
																			   keyEquivalent:@""];
						
						NSString * addonPath = [NSString stringWithFormat:@"%@/%@/", _addonsPath, addon];
						[addonItem setAddon:[OFAddon addonWithPath:addonPath name:addon]];
						[addonItem setTarget:self];
						[_addonsListMenu addItem:addonItem];
					}
				}
				
				[_addAddonItem setSubmenu:_addonsListMenu];
			});
		});
	});
}

// TODO: store last addon path in NSUserDefaults
- (void)setAddonsPath:(id)sender
{
	dispatch_async(dispatch_get_main_queue(), ^{
		NSOpenPanel * openPanel = [NSOpenPanel openPanel];
		[openPanel setDirectoryURL:[NSURL fileURLWithPath:[@"~" stringByExpandingTildeInPath]]];
		[openPanel setCanChooseDirectories:YES];
		[openPanel setTitle:@"Point me at your addons folder"];
		[openPanel beginWithCompletionHandler:^(NSInteger result) {
			if(result == NSFileHandlingPanelOKButton) {
				NSURL * addonsURL = [[openPanel URLs] objectAtIndex:0];
				_addonsPath = [addonsURL path];
				[self scanAddons];
			}
		}];
	});
}

#pragma mark - Actions

- (void)addAddonForMenuItem:(OFAddonMenuItem *)addonMenuItem
{
	// These Obj-C classes found via class-dumping Xcode's internal frameworks
	
	// IDEWorkspaceDocument -> IDEKit
	// IDEWorkspace -> IDEFoundation
	// Xcode3Project, Xcode3Group -> DevToolsCore
	
	@try {
		id /* IDEWorkspaceDocument */ document = [[[NSApp keyWindow] windowController] document];
		id /* IDEWorkspace */ workspace = objc_msgSend(document, @selector(workspace));
		id /* Xcode3Project */ container = objc_msgSend(workspace, @selector(wrappedXcode3Project));
		id /* PBXProject */ project = objc_msgSend(container, @selector(pbxProject));
		id /* Xcode3Group */ addonsGroup = [self findAddonsGroupFromRoot:objc_msgSend(container, @selector(rootGroup))];
		
		if(addonsGroup) {
			[self addAddon:addonMenuItem.addon toGroup:addonsGroup forTargets:objc_msgSend(project, @selector(targets))];
		} else {
			[[NSAlert alertWithMessageText:@"Couldn't find an \"addons\" group"
							 defaultButton:@"Oh, right"
						   alternateButton:nil
							   otherButton:nil
				 informativeTextWithFormat:@"You should have a group called \"addons\" in your project"] runModal];
		}
	}
	@catch (NSException *exception) {
		NSLog(@"PROBLEM! : %@", exception);
	}
	@finally {
		
	}
}

- (void)addAddon:(OFAddon *)addon toGroup:(id /* Xcode3Group */)addonsGroup forTargets:(NSArray *)targets {
	
	NSURL * addonURL = [NSURL fileURLWithPath:addon.path];
	id newGroups = objc_msgSend(addonsGroup, @selector(structureEditInsertFileURLs:atIndex:createGroupsForFolders:), @[addonURL], 0, YES);
	id newGroup = [newGroups objectAtIndex:0];
	
	// remove top-level stuff that's not "src" or "libs"
	[self removeItemsFromGroup:newGroup withSet:[NSSet setWithArray:@[@"src", @"libs"]] isWhiteList:YES recursive:NO];
	
	// remove anything that identifies as being non-osx
	NSMutableSet * foldersToExclude = [NSMutableSet setWithArray:@[@"win32", @"windows", @"vs", @"win_cb", @"linux", @"android"]];
	[foldersToExclude addObjectsFromArray:[addon foldersToExclude]];
	[self removeItemsFromGroup:newGroup withSet:foldersToExclude isWhiteList:NO recursive:YES];
	
	// add all compilable sources to the relevant targets
	id /* PBXGroup */ pbxGroup = objc_msgSend(newGroup, @selector(group));
	id /* PBXGroupEnumerator */ pbxGroupEnumerator = objc_msgSend(pbxGroup, @selector(groupEnumerator));
	
	NSMutableArray * sourceFileReferences = [[NSMutableArray alloc] init];
	NSMutableArray * libReferences = [[NSMutableArray alloc] init];
	for(id item in pbxGroupEnumerator) {
		
		if([item class] != NSClassFromString(@"PBXFileReference")) continue;
		
		id /* PBXFileType */ fileType = objc_msgSend(item, @selector(fileType));
		NSString * fileUTI = objc_msgSend(fileType, @selector(UTI));
		
		// if this is a source file (header files don't count)
		if([fileUTI rangeOfString:@"source"].location != NSNotFound) {
			[sourceFileReferences addObject:item];
		}
		// if this is a static lib
		else if(((BOOL (*)(id, SEL))objc_msgSend)(fileType, @selector(isStaticLibrary))) {
			[libReferences addObject:item];
		}
	}
	
	for(id target in targets) {
		
		// add source files and libraries
		for (id sourceFileReference in sourceFileReferences) {
			objc_msgSend(target, @selector(addReference:), sourceFileReference);
		}
		
		for(id libReference in libReferences) {
			objc_msgSend(target, @selector(addReference:), libReference);
		}
		
		// add the source files to the "Compile Sources" phase
		NSArray * sourcesBuildPhases = objc_msgSend(target, @selector(buildPhasesOfClass:), NSClassFromString(@"PBXSourcesBuildPhase"));
		for(id phase in sourcesBuildPhases) {
			objc_msgSend(phase, @selector(insertBuildFiles:atIndex:), sourceFileReferences, 0);
		}
		
		// add libs to the "link binary with libraries" phase
		NSArray * frameworksBuildPhases = objc_msgSend(target, @selector(buildPhasesOfClass:), NSClassFromString(@"PBXFrameworksBuildPhase"));
		for(id phase in frameworksBuildPhases) {
			objc_msgSend(phase, @selector(insertBuildFiles:atIndex:), libReferences, 0);
		}
	}
}

#pragma mark - Util

// breadth first search for a group named "addons"
- (id) findAddonsGroupFromRoot:(id /* Xcode3Group */)root {
	
	if(root == nil) return nil;
	
	NSMutableArray * queue = [[NSMutableArray alloc] init];
	[queue addObject:root];
	
	while([queue count] > 0) {
		id node = [queue objectAtIndex:0];
		[queue removeObjectAtIndex:0];
		NSString * nodeName = objc_msgSend(node, @selector(name));
		if([nodeName caseInsensitiveCompare:@"addons"] == NSOrderedSame) {
			return node;
		} else {
			if([node respondsToSelector:@selector(subitems)]) {
				NSArray * subitems = objc_msgSend(node, @selector(subitems));
				for(id item in subitems) {
					[queue addObject:item];
				}
			}
		}
	}
	
	return nil;
}

- (void) removeItemsFromGroup:(id)group withSet:(NSSet *)set isWhiteList:(BOOL)whiteList recursive:(BOOL)recursive {

	if(!group || ![group respondsToSelector:@selector(subitems)]) {
		return;
	} else {
		NSArray * subitems = objc_msgSend(group, @selector(subitems));
		if(recursive) {
			for(id item in subitems) {
				[self removeItemsFromGroup:item withSet:set isWhiteList:whiteList recursive:YES];
			}
		}
		NSMutableIndexSet * stuffToRemove = [[NSMutableIndexSet alloc] init];
		for(NSUInteger i = 0; i < subitems.count; i++) {
			NSString * itemName = objc_msgSend(subitems[i], @selector(name));
			BOOL shouldRemove = NO;
			for(NSString * ident in set) {
				if([itemName rangeOfString:ident].location != NSNotFound) {
					shouldRemove = YES;
					break;
				}
			}
			if(whiteList) {
				shouldRemove = !shouldRemove;
			}
			if(shouldRemove) {
				[stuffToRemove addIndex:i];
			}
		}
		NSError * err = nil;
		objc_msgSend(group, @selector(structureEditRemoveSubitemsAtIndexes:error:), stuffToRemove, &err);
		if(err) {
			NSLog(@"Error when removing %@", err);
		}
	}
}

@end
