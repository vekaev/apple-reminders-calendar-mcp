#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Writes through Apple's private ReminderKit (the framework Reminders.app uses), for the things the public
/// EventKit API can't do. Changes sync through iCloud like edits made in the app. Reminder ids are the
/// EventKit `calendarItemIdentifier` (same UUID as ReminderKit's object id).
@interface RKBridge : NSObject
/// Whether ReminderKit loaded and has the selectors we rely on (it's private, so it can change with macOS).
+ (BOOL)isAvailable;
/// The reminder's title as ReminderKit sees it (a read-only check that an id maps correctly).
+ (nullable NSString *)titleOfReminder:(NSString *)identifier error:(NSError **)error;
/// Every list with its group and account: [{id, name, groupId?, groupName?, account, accountId}] plus groups
/// under "groups": [{id, name, account}]. Read-only.
+ (nullable NSDictionary *)listsAndGroupsWithError:(NSError **)error NS_SWIFT_NAME(listsAndGroups());
/// Reminders (including subtasks) in the given lists: [{id, title, notes?, listId, completed, completedAt?, priority,
/// due?, dueHasTime, start?, flagged, tags[], parentId?, urls[], created?, modified?, recurring}]. Read-only.
+ (nullable NSArray<NSDictionary *> *)remindersInLists:(NSArray<NSString *> *)listIDs includeCompleted:(BOOL)includeCompleted error:(NSError **)error NS_SWIFT_NAME(reminders(inLists:includeCompleted:));
/// The reminder's current tags (names without '#').
+ (nullable NSArray<NSString *> *)tagsOfReminder:(NSString *)identifier error:(NSError **)error NS_SWIFT_NAME(tags(ofReminder:));
/// Replaces the reminder's tags (Reminders' Tags sidebar) with `tags` (names without '#'; empty clears).
+ (BOOL)setTags:(NSArray<NSString *> *)tags onReminder:(NSString *)identifier error:(NSError **)error;
/// Whether the reminder is marked Urgent (nil if unknown).
+ (nullable NSNumber *)urgentOfReminder:(NSString *)identifier error:(NSError **)error NS_SWIFT_NAME(urgent(ofReminder:));
/// Marks the reminder Urgent (an alarm that rings like a timer) or not.
+ (BOOL)setUrgent:(BOOL)urgent onReminder:(NSString *)identifier error:(NSError **)error;
/// Adds subtasks under the reminder; returns their ids.
+ (nullable NSArray<NSString *> *)addSubtasks:(NSArray<NSString *> *)titles toReminder:(NSString *)identifier error:(NSError **)error NS_SWIFT_NAME(addSubtasks(_:toReminder:));
/// Creates a list group in the account of `listInAccount` (any list id); returns the group id.
+ (nullable NSString *)createGroup:(NSString *)name inAccountOfList:(NSString *)listInAccount error:(NSError **)error NS_SWIFT_NAME(createGroup(_:inAccountOfList:));
/// Puts a list into a group (nil takes it out of its group).
+ (BOOL)setGroup:(nullable NSString *)groupID forList:(NSString *)listID error:(NSError **)error NS_SWIFT_NAME(setGroup(_:forList:));
/// Removes an (empty or not) list group; its lists move out of it. Used by tests to clean up — the server never deletes.
+ (BOOL)deleteGroup:(NSString *)groupID error:(NSError **)error;
/// A list's sections, in order: [{id, name}].
+ (nullable NSArray<NSDictionary *> *)sectionsOfList:(NSString *)listID error:(NSError **)error NS_SWIFT_NAME(sections(ofList:));
/// Adds a section at the end of a list; returns its id.
+ (nullable NSString *)createSection:(NSString *)name inList:(NSString *)listID error:(NSError **)error NS_SWIFT_NAME(createSection(_:inList:));
/// Puts a reminder in a section of its list (nil takes it out of any section).
+ (BOOL)putReminder:(NSString *)identifier inSection:(nullable NSString *)sectionID error:(NSError **)error NS_SWIFT_NAME(putReminder(_:inSection:));
/// Sets or clears the flag.
+ (BOOL)setFlagged:(BOOL)flagged onReminder:(NSString *)identifier error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
