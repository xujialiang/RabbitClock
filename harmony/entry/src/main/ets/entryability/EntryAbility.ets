import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { AppState, Prefs } from '../data/Prefs';
import { TimeSync } from '../timesync/TimeSync';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 轻量存储与全局状态初始化
    Prefs.init(this.context).then(() => {
      Prefs.loadStyle().then((s) => {
        AppState.style = s;
      });
      TimeSync.load(); // 时间源选择/微调/上次校准结果（默认北京时间，加载不联网）
    });
    // 周期补校准：进程存活期间每 10 分钟过一次新鲜度闸门（新鲜则不发请求）
    setInterval(() => TimeSync.ensureFresh(), 10 * 60 * 1000);
    // 将 UIAbility 上下文放入 AppStorage 供页面使用（悬浮窗创建需要它）
    AppStorage.setOrCreate('abilityContext', this.context);
  }

  onForeground(): void {
    // 回前台自动补校准（10 分钟新鲜度闸门，新鲜则不发请求）
    TimeSync.ensureFresh();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error(`[Entry] loadContent failed: ${JSON.stringify(err)}`);
      }
    });
  }
}
