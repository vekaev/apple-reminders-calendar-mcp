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
/// Sets or clears the flag.
+ (BOOL)setFlagged:(BOOL)flagged onReminder:(NSString *)identifier error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
