// Interfaces below are private ReminderKit API, declared the same way as viticci/remctl (MIT).
#import "RKBridge.h"

@interface REMObjectID : NSObject
+ (id)objectIDWithURL:(NSURL *)url;
@end

@interface REMStore : NSObject
- (id)fetchReminderWithObjectID:(id)objectID error:(NSError **)error;
- (NSArray *)fetchAccountsWithError:(NSError **)error;
- (id)fetchListWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListIncludingSpecialContainerWithObjectID:(id)objectID error:(NSError **)error;
@end

@interface NSObject (RKAccountAndList)
- (NSArray *)fetchListsAndSublistsWithError:(NSError **)error;
- (NSArray *)fetchListsWithError:(NSError **)error;
- (NSArray *)fetchRemindersAndSubtasksWithError:(NSError **)error;
- (NSArray *)fetchRemindersWithError:(NSError **)error;
- (NSArray *)fetchGroupsWithError:(NSError **)error;
- (NSArray *)fetchListSectionsWithListObjectID:(id)objectID error:(NSError **)error;
- (id)sectionsContextChangeItem;
- (id)addListSectionWithDisplayName:(NSString *)name toListSectionContextChangeItem:(id)context;
- (void)setUnsavedSectionIDsOrdering:(id)ordering;
- (void)setShouldUpdateSectionsOrdering:(BOOL)value;
- (void)setUnsavedMembershipsOfRemindersInSections:(id)memberships;
- (id)initWithMemberIdentifier:(id)member groupIdentifier:(id)group isObsolete:(BOOL)obsolete modifiedOn:(id)date;
- (id)initWithMemberships:(NSArray *)memberships;
- (id)uuid;
@end

@interface REMSaveRequest : NSObject
- (instancetype)initWithStore:(REMStore *)store;
- (id)updateReminder:(id)reminder;
- (BOOL)saveSynchronouslyWithError:(NSError **)error;
@end

@interface REMReminderChangeItem : NSObject
- (id)flaggedContext;
- (id)hashtagContext;
- (id)urgentAlarmContext;
- (id)subtaskContext;
- (id)remObjectID;
@end

@interface REMReminderUrgentAlarmContextChangeItem : NSObject
- (void)setIsUrgentStateEnabledForCurrentUser:(BOOL)value;
@end

@interface NSObject (RKLists)
- (id)updateList:(id)list;
- (id)updateAccount:(id)account;
- (id)groupContext;
- (id)account;
- (id)remObjectID;
- (void)setParentOwnerID:(id)objectID;
- (void)setParentSubContainerID:(id)objectID;
- (void)removeFromParentWithAccountChangeItem:(id)accountChangeItem;
- (id)addGroupWithName:(NSString *)name toAccountGroupContextChangeItem:(id)context;
- (id)addGroupWithName:(NSString *)name toAccountGroupContextChangeItem:(id)context groupObjectID:(id)objectID;
- (id)addReminderWithTitle:(NSString *)title toReminderSubtaskContextChangeItem:(id)context;
@end

@interface REMReminderHashtagContextChangeItem : NSObject
- (id)addHashtagWithType:(NSInteger)type name:(NSString *)name;
- (void)removeAllHashtags;
@end

@interface REMReminderFlaggedContextChangeItem : NSObject
- (void)setFlagged:(NSInteger)flagged;
@end

@interface REMReminder : NSObject
- (NSString *)titleAsString;
@end

static id KV(id object, NSString *key) {
    @try { return [object valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static NSString *UUIDOf(id objectID) {
    id uuid = KV(objectID, @"uuid");
    return [uuid isKindOfClass:[NSUUID class]] ? [(NSUUID *)uuid UUIDString] : nil;
}

static NSString *ISODate(NSDate *date) {
    static NSISO8601DateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSISO8601DateFormatter new]; f.timeZone = NSTimeZone.localTimeZone; });
    return date ? [f stringFromDate:date] : nil;
}

/// "2026-10-20" for an all-day date, "2026-10-20T14:30:00-07:00" with a time.
static NSString *ComponentsString(NSDateComponents *c, BOOL *hasTime) {
    if (![c isKindOfClass:[NSDateComponents class]] || c.year == NSDateComponentUndefined) return nil;
    BOOL time = c.hour != NSDateComponentUndefined;
    if (hasTime) *hasTime = time;
    if (!time) return [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)c.year, (long)c.month, (long)c.day];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *d = [cal dateFromComponents:c];
    return ISODate(d);
}

static NSError *RKError(NSString *message) {
    return [NSError errorWithDomain:@"ReminderKitBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation RKBridge

+ (BOOL)isAvailable {
    Class store = NSClassFromString(@"REMStore");
    Class save = NSClassFromString(@"REMSaveRequest");
    Class oid = NSClassFromString(@"REMObjectID");
    return store && save && oid
        && [store instancesRespondToSelector:@selector(fetchReminderWithObjectID:error:)]
        && [save instancesRespondToSelector:@selector(updateReminder:)]
        && [save instancesRespondToSelector:@selector(saveSynchronouslyWithError:)];
}

+ (nullable id)fetch:(NSString *)identifier store:(REMStore *)store error:(NSError **)error {
    if (![self isAvailable]) { if (error) *error = RKError(@"ReminderKit isn't available on this macOS version"); return nil; }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://REMCDReminder/%@", identifier]];
    id objectID = url ? [NSClassFromString(@"REMObjectID") objectIDWithURL:url] : nil;
    if (!objectID) { if (error) *error = RKError(@"Bad reminder id"); return nil; }
    NSError *fetchError = nil;
    id reminder = [store fetchReminderWithObjectID:objectID error:&fetchError];
    if (!reminder && error) *error = fetchError ?: RKError(@"Reminder not found");
    return reminder;
}

+ (nullable NSDictionary *)listsAndGroupsWithError:(NSError **)error {
    if (![self isAvailable]) { if (error) *error = RKError(@"ReminderKit isn't available on this macOS version"); return nil; }
    @try {
        id store = [NSClassFromString(@"REMStore") new];
        NSError *e = nil;
        NSArray *accounts = [store fetchAccountsWithError:&e];
        if (!accounts) { if (error) *error = e ?: RKError(@"Couldn't read Reminders accounts"); return nil; }
        NSMutableArray *lists = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSDictionary *> *groups = [NSMutableDictionary dictionary];
        for (id account in accounts) {
            if ([KV(account, @"inactive") boolValue]) continue;
            NSString *accountName = [KV(account, @"name") description] ?: @"";
            NSString *accountID = UUIDOf(KV(account, @"objectID")) ?: @"";
            // Every group of the account, including empty ones (lists only point at groups that contain them).
            id groupContext = KV(account, @"groupContext");
            if ([groupContext respondsToSelector:@selector(fetchGroupsWithError:)]) {
                for (id g in [groupContext fetchGroupsWithError:nil] ?: @[]) {
                    NSString *gid = UUIDOf(KV(g, @"objectID"));
                    if (gid && !groups[gid]) groups[gid] = @{@"id": gid, @"name": [KV(g, @"name") description] ?: @"", @"account": accountName};
                }
            }
            NSArray *ls = [account respondsToSelector:@selector(fetchListsAndSublistsWithError:)]
                ? [account fetchListsAndSublistsWithError:nil] : [account fetchListsWithError:nil];
            for (id list in ls) {
                if ([KV(list, @"isGroup") boolValue]) continue;
                NSString *listID = UUIDOf(KV(list, @"objectID"));
                if (!listID) continue;
                NSMutableDictionary *o = [@{@"id": listID, @"name": [KV(list, @"name") description] ?: @"",
                                            @"account": accountName, @"accountId": accountID} mutableCopy];
                if ([KV(KV(list, @"sectionContext"), @"hasSections") boolValue]) {
                    NSArray *secs = [self sectionsOfList:listID error:nil];
                    if (secs.count) o[@"sections"] = secs;
                }
                id parentID = KV(list, @"parentListID");
                NSString *groupID = parentID ? UUIDOf(parentID) : nil;
                if (groupID) {
                    if (!groups[groupID]) {
                        id group = [store fetchListIncludingSpecialContainerWithObjectID:parentID error:nil];
                        groups[groupID] = @{@"id": groupID, @"name": [KV(group, @"name") description] ?: @"", @"account": accountName};
                    }
                    o[@"groupId"] = groupID;
                    o[@"groupName"] = groups[groupID][@"name"];
                }
                [lists addObject:o];
            }
        }
        return @{@"lists": lists, @"groups": groups.allValues};
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return nil;
    }
}

+ (nullable NSArray<NSDictionary *> *)remindersInLists:(NSArray<NSString *> *)listIDs includeCompleted:(BOOL)includeCompleted error:(NSError **)error {
    if (![self isAvailable]) { if (error) *error = RKError(@"ReminderKit isn't available on this macOS version"); return nil; }
    @try {
        id store = [NSClassFromString(@"REMStore") new];
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *listID in listIDs) {
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://REMCDList/%@", listID]];
            id objectID = url ? [NSClassFromString(@"REMObjectID") objectIDWithURL:url] : nil;
            id list = objectID ? [store fetchListWithObjectID:objectID error:nil] : nil;
            if (!list) continue;
            NSArray *rs = [list respondsToSelector:@selector(fetchRemindersAndSubtasksWithError:)]
                ? [list fetchRemindersAndSubtasksWithError:nil] : [list fetchRemindersWithError:nil];
            for (id r in rs) {
                BOOL completed = [KV(r, @"completed") boolValue];
                if (completed && !includeCompleted) continue;
                NSString *rid = UUIDOf(KV(r, @"objectID"));
                if (!rid) continue;
                NSMutableDictionary *o = [NSMutableDictionary dictionary];
                o[@"id"] = rid;
                o[@"title"] = ([r respondsToSelector:@selector(titleAsString)] ? [r titleAsString] : [KV(r, @"title") description]) ?: @"";
                NSString *notes = [r respondsToSelector:NSSelectorFromString(@"notesAsString")] ? KV(r, @"notesAsString") : nil;
                if ([notes isKindOfClass:[NSString class]] && notes.length) o[@"notes"] = notes;
                o[@"listId"] = listID;
                o[@"completed"] = @(completed);
                if (completed) { NSString *c = ISODate(KV(r, @"completionDate")); if (c) o[@"completedAt"] = c; }
                o[@"priority"] = KV(r, @"priority") ?: @0;
                BOOL hasTime = NO;
                NSString *due = ComponentsString(KV(r, @"dueDateComponents"), &hasTime);
                if (due) { o[@"due"] = due; }
                NSString *start = ComponentsString(KV(r, @"startDateComponents"), NULL);
                if (start) o[@"start"] = start;
                o[@"flagged"] = @([KV(r, @"flagged") boolValue]);
                if ([KV(r, @"isUrgentStateEnabledForCurrentUser") boolValue]) o[@"urgent"] = @YES;
                id alarms = KV(r, @"alarms");
                if ([alarms count]) o[@"alarms"] = @([alarms count]);
                NSMutableArray *tags = [NSMutableArray array];
                id hashtags = KV(r, @"hashtags");
                for (id t in ([hashtags respondsToSelector:@selector(allObjects)] ? [hashtags allObjects] : hashtags)) {
                    NSString *name = [KV(t, @"name") description];
                    if (name.length && ![tags containsObject:name]) [tags addObject:name];
                }
                [tags sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
                o[@"tags"] = tags;
                NSString *parent = UUIDOf(KV(r, @"parentReminderID"));
                if (parent) o[@"parentId"] = parent;
                NSMutableArray *urls = [NSMutableArray array];
                for (id a in KV(r, @"attachments")) {
                    id u = KV(a, @"url");
                    if ([u isKindOfClass:[NSURL class]] && ![(NSURL *)u isFileURL]) [urls addObject:[(NSURL *)u absoluteString]];
                }
                if (urls.count) o[@"urls"] = urls;
                NSString *created = ISODate(KV(r, @"creationDate")); if (created) o[@"created"] = created;
                NSString *modified = ISODate(KV(r, @"lastModifiedDate")); if (modified) o[@"modified"] = modified;
                if ([KV(r, @"recurrenceRules") count]) o[@"recurring"] = @YES;
                [out addObject:o];
            }
        }
        return out;
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return nil;
    }
}

+ (nullable NSString *)titleOfReminder:(NSString *)identifier error:(NSError **)error {
    @try {
        REMStore *store = [NSClassFromString(@"REMStore") new];
        id reminder = [self fetch:identifier store:store error:error];
        if (!reminder) return nil;
        if ([reminder respondsToSelector:@selector(titleAsString)]) return [reminder titleAsString] ?: @"";
        id title = [reminder valueForKey:@"title"];
        return [title isKindOfClass:[NSString class]] ? title : [title description];
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return nil;
    }
}

+ (nullable NSArray<NSString *> *)tagsOfReminder:(NSString *)identifier error:(NSError **)error {
    @try {
        REMStore *store = [NSClassFromString(@"REMStore") new];
        id reminder = [self fetch:identifier store:store error:error];
        if (!reminder) return nil;
        NSMutableArray *tags = [NSMutableArray array];
        id hashtags = KV(reminder, @"hashtags");
        for (id t in ([hashtags respondsToSelector:@selector(allObjects)] ? [hashtags allObjects] : hashtags)) {
            NSString *name = [KV(t, @"name") description];
            if (name.length && ![tags containsObject:name]) [tags addObject:name];
        }
        return tags;
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return nil;
    }
}

+ (BOOL)change:(NSString *)identifier error:(NSError **)error with:(BOOL (^)(REMReminderChangeItem *change, NSError **error))edit {
    @try {
        REMStore *store = [NSClassFromString(@"REMStore") new];
        id reminder = [self fetch:identifier store:store error:error];
        if (!reminder) return NO;
        REMSaveRequest *save = [[NSClassFromString(@"REMSaveRequest") alloc] initWithStore:store];
        REMReminderChangeItem *change = [save updateReminder:reminder];
        if (!change) { if (error) *error = RKError(@"Couldn't start a ReminderKit change"); return NO; }
        if (!edit(change, error)) return NO;
        return [save saveSynchronouslyWithError:error];
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return NO;
    }
}

+ (BOOL)setTags:(NSArray<NSString *> *)tags onReminder:(NSString *)identifier error:(NSError **)error {
    return [self change:identifier error:error with:^BOOL(REMReminderChangeItem *change, NSError **err) {
        id context = [change respondsToSelector:@selector(hashtagContext)] ? [change hashtagContext] : nil;
        if (!context || ![context respondsToSelector:@selector(removeAllHashtags)] || ![context respondsToSelector:@selector(addHashtagWithType:name:)]) {
            if (err) *err = RKError(@"ReminderKit tags aren't available on this macOS version");
            return NO;
        }
        [context removeAllHashtags];
        for (NSString *tag in tags) {
            if (tag.length) [context addHashtagWithType:1 name:tag];
        }
        return YES;
    }];
}

+ (nullable NSNumber *)urgentOfReminder:(NSString *)identifier error:(NSError **)error {
    @try {
        REMStore *store = [NSClassFromString(@"REMStore") new];
        id reminder = [self fetch:identifier store:store error:error];
        if (!reminder) return nil;
        id v = KV(reminder, @"isUrgentStateEnabledForCurrentUser");
        return [v isKindOfClass:[NSNumber class]] ? v : @NO;
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return nil;
    }
}

+ (BOOL)setUrgent:(BOOL)urgent onReminder:(NSString *)identifier error:(NSError **)error {
    return [self change:identifier error:error with:^BOOL(REMReminderChangeItem *change, NSError **err) {
        id context = [change respondsToSelector:@selector(urgentAlarmContext)] ? [change urgentAlarmContext] : nil;
        if (!context || ![context respondsToSelector:@selector(setIsUrgentStateEnabledForCurrentUser:)]) {
            if (err) *err = RKError(@"Urgent reminders aren't available on this macOS version");
            return NO;
        }
        [context setIsUrgentStateEnabledForCurrentUser:urgent];
        return YES;
    }];
}

+ (nullable NSArray<NSString *> *)addSubtasks:(NSArray<NSString *> *)titles toReminder:(NSString *)identifier error:(NSError **)error {
    NSMutableArray *ids = [NSMutableArray array];
    @try {
        REMStore *store = [NSClassFromString(@"REMStore") new];
        id reminder = [self fetch:identifier store:store error:error];
        if (!reminder) return nil;
        REMSaveRequest *save = [[NSClassFromString(@"REMSaveRequest") alloc] initWithStore:store];
        REMReminderChangeItem *change = [save updateReminder:reminder];
        id context = [change respondsToSelector:@selector(subtaskContext)] ? [change subtaskContext] : nil;
        if (!context || ![save respondsToSelector:@selector(addReminderWithTitle:toReminderSubtaskContextChangeItem:)]) {
            if (error) *error = RKError(@"Subtasks aren't available on this macOS version");
            return nil;
        }
        for (NSString *title in titles) {
            id sub = [(id)save addReminderWithTitle:title toReminderSubtaskContextChangeItem:context];
            NSString *sid = UUIDOf([sub remObjectID]);
            if (sid) [ids addObject:sid];
        }
        if (![save saveSynchronouslyWithError:error]) return nil;
        return ids;
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return nil;
    }
}

+ (nullable id)fetchList:(NSString *)listID store:(REMStore *)store error:(NSError **)error {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://REMCDList/%@", listID]];
    id oid = url ? [NSClassFromString(@"REMObjectID") objectIDWithURL:url] : nil;
    id list = oid ? [store fetchListWithObjectID:oid error:nil] : nil;
    if (!list) list = oid ? [store fetchListIncludingSpecialContainerWithObjectID:oid error:nil] : nil;
    if (!list && error) *error = RKError([NSString stringWithFormat:@"List %@ not found", listID]);
    return list;
}

+ (nullable NSString *)createGroup:(NSString *)name inAccountOfList:(NSString *)listInAccount error:(NSError **)error {
    @try {
        REMStore *store = [NSClassFromString(@"REMStore") new];
        id list = [self fetchList:listInAccount store:store error:error];
        id account = list ? [list account] : nil;
        if (!account) { if (error && !*error) *error = RKError(@"No Reminders account for that list"); return nil; }
        REMSaveRequest *save = [[NSClassFromString(@"REMSaveRequest") alloc] initWithStore:store];
        id accountChange = [(id)save updateAccount:account];
        id groupContext = [accountChange respondsToSelector:@selector(groupContext)] ? [accountChange groupContext] : nil;
        if (!groupContext) { if (error) *error = RKError(@"List groups aren't available for this account"); return nil; }
        id change = [save respondsToSelector:@selector(addGroupWithName:toAccountGroupContextChangeItem:groupObjectID:)]
            ? [(id)save addGroupWithName:name toAccountGroupContextChangeItem:groupContext groupObjectID:nil]
            : [(id)save addGroupWithName:name toAccountGroupContextChangeItem:groupContext];
        if (!change) { if (error) *error = RKError(@"Couldn't create the group"); return nil; }
        if ([change respondsToSelector:@selector(setParentOwnerID:)]) [change setParentOwnerID:[account remObjectID]];
        if (![save saveSynchronouslyWithError:error]) return nil;
        return UUIDOf([change remObjectID]);
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return nil;
    }
}

+ (BOOL)setGroup:(nullable NSString *)groupID forList:(NSString *)listID error:(NSError **)error {
    @try {
        REMStore *store = [NSClassFromString(@"REMStore") new];
        id list = [self fetchList:listID store:store error:error];
        if (!list) return NO;
        id groupObjectID = nil;
        if (groupID.length) {
            groupObjectID = [NSClassFromString(@"REMObjectID") objectIDWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://REMCDList/%@", groupID]]];
            if (![self fetchList:groupID store:store error:error]) return NO;
        }
        REMSaveRequest *save = [[NSClassFromString(@"REMSaveRequest") alloc] initWithStore:store];
        id change = [(id)save updateList:list];
        if (![change respondsToSelector:@selector(setParentSubContainerID:)]) { if (error) *error = RKError(@"Moving lists between groups isn't available"); return NO; }
        if ([change respondsToSelector:@selector(setParentOwnerID:)]) [change setParentOwnerID:[[list account] remObjectID]];
        [change setParentSubContainerID:groupObjectID];
        return [save saveSynchronouslyWithError:error];
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return NO;
    }
}

+ (BOOL)deleteGroup:(NSString *)groupID error:(NSError **)error {
    @try {
        REMStore *store = [NSClassFromString(@"REMStore") new];
        id group = [self fetchList:groupID store:store error:error];
        if (!group) return NO;
        REMSaveRequest *save = [[NSClassFromString(@"REMSaveRequest") alloc] initWithStore:store];
        id accountChange = [(id)save updateAccount:[group account]];
        id change = [(id)save updateList:group];
        [change removeFromParentWithAccountChangeItem:accountChange];
        return [save saveSynchronouslyWithError:error];
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return NO;
    }
}

+ (nullable id)listObjectID:(NSString *)listID {
    return [NSClassFromString(@"REMObjectID") objectIDWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://REMCDList/%@", listID]]];
}

+ (nullable NSArray<NSDictionary *> *)sectionsOfList:(NSString *)listID error:(NSError **)error {
    @try {
        id store = [NSClassFromString(@"REMStore") new];
        NSArray *secs = [store fetchListSectionsWithListObjectID:[self listObjectID:listID] error:error];
        if (!secs) return nil;
        NSMutableArray *out = [NSMutableArray array];
        for (id s in secs) {
            NSString *sid = UUIDOf(KV(s, @"objectID"));
            if (sid) [out addObject:@{@"id": sid, @"name": [KV(s, @"displayName") description] ?: @""}];
        }
        return out;
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return nil;
    }
}

+ (nullable NSString *)createSection:(NSString *)name inList:(NSString *)listID error:(NSError **)error {
    @try {
        REMStore *store = [NSClassFromString(@"REMStore") new];
        id list = [self fetchList:listID store:store error:error];
        if (!list) return nil;
        NSArray *existing = [(id)store fetchListSectionsWithListObjectID:[self listObjectID:listID] error:nil] ?: @[];
        REMSaveRequest *save = [[NSClassFromString(@"REMSaveRequest") alloc] initWithStore:store];
        id listChange = [(id)save updateList:list];
        id context = [listChange respondsToSelector:@selector(sectionsContextChangeItem)] ? [listChange sectionsContextChangeItem] : nil;
        if (!context) { if (error) *error = RKError(@"Sections aren't available for this list"); return nil; }
        id section = [(id)save addListSectionWithDisplayName:name toListSectionContextChangeItem:context];
        id sectionID = [section remObjectID];
        NSMutableArray *ordering = [NSMutableArray array];
        for (id s in existing) { id oid = KV(s, @"objectID"); if (oid) [ordering addObject:oid]; }
        if (sectionID) [ordering addObject:sectionID];
        [context setUnsavedSectionIDsOrdering:ordering];
        [context setShouldUpdateSectionsOrdering:YES];
        if (![save saveSynchronouslyWithError:error]) return nil;
        return UUIDOf(sectionID);
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return nil;
    }
}

+ (BOOL)putReminder:(NSString *)identifier inSection:(nullable NSString *)sectionID error:(NSError **)error {
    @try {
        REMStore *store = [NSClassFromString(@"REMStore") new];
        id reminder = [self fetch:identifier store:store error:error];
        if (!reminder) return NO;
        id list = KV(reminder, @"list");
        NSString *listID = UUIDOf(KV(list, @"objectID"));
        NSArray *sections = listID ? [self sectionsOfList:listID error:nil] : nil;
        NSString *target = sectionID;
        BOOL obsolete = NO;
        if (!target) {
            // Out of any section: an obsolete membership (needs some section of the list as its group).
            target = [sections.firstObject objectForKey:@"id"];
            obsolete = YES;
            if (!target) return YES; // the list has no sections, so the reminder isn't in one
        }
        REMSaveRequest *save = [[NSClassFromString(@"REMSaveRequest") alloc] initWithStore:store];
        id listChange = [(id)save updateList:list];
        id context = [listChange respondsToSelector:@selector(sectionsContextChangeItem)] ? [listChange sectionsContextChangeItem] : nil;
        if (![context respondsToSelector:@selector(setUnsavedMembershipsOfRemindersInSections:)]) {
            if (error) *error = RKError(@"Sections aren't available on this macOS version"); return NO;
        }
        NSUUID *member = [[NSUUID alloc] initWithUUIDString:identifier];
        NSUUID *group = [[NSUUID alloc] initWithUUIDString:target];
        id membership = [[NSClassFromString(@"REMMembership") alloc] initWithMemberIdentifier:member groupIdentifier:group isObsolete:obsolete modifiedOn:[NSDate date]];
        [context setUnsavedMembershipsOfRemindersInSections:[[NSClassFromString(@"REMMemberships") alloc] initWithMemberships:@[membership]]];
        return [save saveSynchronouslyWithError:error];
    } @catch (NSException *e) {
        if (error) *error = RKError([NSString stringWithFormat:@"ReminderKit: %@", e.reason]);
        return NO;
    }
}

+ (BOOL)setFlagged:(BOOL)flagged onReminder:(NSString *)identifier error:(NSError **)error {
    return [self change:identifier error:error with:^BOOL(REMReminderChangeItem *change, NSError **err) {
        id context = [change respondsToSelector:@selector(flaggedContext)] ? [change flaggedContext] : nil;
        if (!context || ![context respondsToSelector:@selector(setFlagged:)]) {
            if (err) *err = RKError(@"ReminderKit flags aren't available on this macOS version");
            return NO;
        }
        [context setFlagged:flagged ? 1 : 0];
        return YES;
    }];
}

@end
