import { reminderAgentManager } from '@kit.BackgroundTasksKit';

/**
 * 代理提醒兜底：倒计时到点由系统触发（应用进程被挂起/被杀也照常提醒）。
 * 倒计时启动时登记，暂停/取消/重置时撤销。
 */
export class ReminderHelper {
  private static reminderId: number = -1;

  static async scheduleCountdown(endWallMs: number): Promise<void> {
    await ReminderHelper.cancel();
    const d = new Date(endWallMs);
    const reminder: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: d.getFullYear(),
        month: d.getMonth() + 1,
        day: d.getDate(),
        hour: d.getHours(),
        minute: d.getMinutes(),
        second: d.getSeconds(),
      },
      title: '兔时笺 · 时间到',
      content: '倒计时已结束',
      expiredContent: '倒计时已结束',
      notificationId: 1001,
      ringDuration: 15,
      snoozeTimes: 0,
    };
    try {
      ReminderHelper.reminderId = await reminderAgentManager.publishReminder(reminder);
    } catch (e) {
      console.error(`[Reminder] publish failed: ${e instanceof Error ? e.message : ''}`);
    }
  }

  static async cancel(): Promise<void> {
    if (ReminderHelper.reminderId >= 0) {
      try {
        await reminderAgentManager.cancelReminder(ReminderHelper.reminderId);
      } catch (e) {
        console.error(`[Reminder] cancel failed: ${e instanceof Error ? e.message : ''}`);
      }
      ReminderHelper.reminderId = -1;
    }
  }
}
