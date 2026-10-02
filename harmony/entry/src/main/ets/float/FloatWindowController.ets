import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppState } from '../data/Prefs';

/**
 * 全局悬浮窗控制器：window.createWindow(TYPE_FLOAT)。
 * 权限：ohos.permission.FLOAT_WINDOW（user_grant，见 module.json5）。
 * 窗口为透明容器，内容由 FloatPage 居中渲染；拖动 = moveWindowTo。
 */
export class FloatWindowController {
  private static win: window.Window | null = null;
  static readonly NAME: string = 'floatClock';

  static isShowing(): boolean {
    return FloatWindowController.win !== null;
  }

  static async show(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      if (FloatWindowController.win) {
        await FloatWindowController.win.showWindow();
        return true;
      }
      const s = AppState.style;
      const w = await window.createWindow({
        name: FloatWindowController.NAME,
        windowType: window.WindowType.TYPE_FLOAT,
        ctx: ctx,
      });
      await w.setUIContent('pages/FloatPage');
      await w.setWindowBackgroundColor('#00000000');
      await w.resize(480, 260);
      await w.moveWindowTo(s.x >= 0 ? s.x : 120, s.y >= 0 ? s.y : 180);
      await w.showWindow();
      FloatWindowController.win = w;
      return true;
    } catch (e) {
      console.error(`[FloatWindow] create failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
      return false;
    }
  }

  static async move(x: number, y: number): Promise<void> {
    try {
      const w = FloatWindowController.win;
      if (w) {
        await w.moveWindowTo(x, y);
      }
    } catch (e) {
      console.error(`[FloatWindow] move failed: ${e instanceof Error ? e.message : ''}`);
    }
  }

  static async resizeTo(width: number, height: number): Promise<void> {
    try {
      const w = FloatWindowController.win;
      if (w) {
        await w.resize(width, height);
      }
    } catch (e) {
      console.error(`[FloatWindow] resize failed: ${e instanceof Error ? e.message : ''}`);
    }
  }

  static async destroy(): Promise<void> {
    try {
      const w = FloatWindowController.win;
      FloatWindowController.win = null;
      if (w) {
        await w.destroyWindow();
      }
    } catch (e) {
      console.error(`[FloatWindow] destroy failed: ${e instanceof Error ? e.message : ''}`);
    }
  }
}
