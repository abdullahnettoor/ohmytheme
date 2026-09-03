import * as vscode from "vscode";
import {
  ApplyThemeAckMessage,
  ApplyThemeMessage,
  OverrideEntry,
} from "./protocol";

const THEME_SETTING = "workbench.colorTheme";

/**
 * Applies a theme change through VS Code's supported configuration
 * API and reports the effective outcome, including overrides at
 * workspace, workspace-folder, or remote scope.
 *
 * The service intentionally uses `WorkspaceConfiguration.update` with
 * `ConfigurationTarget.Global` — the only scope this proof supports —
 * and never edits `settings.json` directly.
 */
export class ThemeService {
  async apply(request: ApplyThemeMessage): Promise<ApplyThemeAckMessage> {
    if (request.target !== "global") {
      return this.failed(request, "unsupported_target", `target '${request.target}' not supported`);
    }

    if (!this.isKnownTheme(request.themeName)) {
      return {
        type: "apply_theme_ack",
        protocolVersion: request.protocolVersion,
        id: request.id,
        status: "unsupported_theme",
        requestedSetting: request.themeName,
        effectiveSetting: this.effectiveTheme(),
        overrides: this.collectOverrides(),
      };
    }

    try {
      await vscode.workspace
        .getConfiguration()
        .update(THEME_SETTING, request.themeName, vscode.ConfigurationTarget.Global);
    } catch (error) {
      return this.failed(
        request,
        "update_threw",
        error instanceof Error ? error.message : String(error),
      );
    }

    const effective = this.effectiveTheme();
    const overrides = this.collectOverrides();
    const status = effective === request.themeName ? "applied" : "overridden";

    return {
      type: "apply_theme_ack",
      protocolVersion: request.protocolVersion,
      id: request.id,
      status,
      requestedSetting: request.themeName,
      effectiveSetting: effective,
      overrides,
    };
  }

  /** Return the currently effective `workbench.colorTheme`. */
  effectiveTheme(): string | undefined {
    const value = vscode.workspace.getConfiguration().get<string>(THEME_SETTING);
    return typeof value === "string" ? value : undefined;
  }

  /**
   * Enumerate scopes that would take precedence over the global
   * setting so the app can surface them in receipts. VS Code exposes
   * `inspect` which reports the values seen at every scope.
   */
  collectOverrides(): OverrideEntry[] {
    const inspection = vscode.workspace.getConfiguration().inspect<string>(THEME_SETTING);
    if (!inspection) return [];

    // If the global value has never been set we still want to surface
    // any narrower-scope value the extension can see — in that case
    // every narrower value is effectively an override because the
    // requested apply cannot compete with a scope that is present.
    const globalValue = inspection.globalValue;
    const differsFromGlobal = (value: string): boolean =>
      globalValue === undefined || value !== globalValue;

    const overrides: OverrideEntry[] = [];
    if (typeof inspection.workspaceValue === "string" && differsFromGlobal(inspection.workspaceValue)) {
      overrides.push({ scope: "workspace", value: inspection.workspaceValue });
    }
    if (typeof inspection.workspaceFolderValue === "string" && differsFromGlobal(inspection.workspaceFolderValue)) {
      const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
      overrides.push({
        scope: "workspaceFolder",
        folder,
        value: inspection.workspaceFolderValue,
      });
    }
    if (
      typeof inspection.workspaceLanguageValue === "string" ||
      typeof inspection.workspaceFolderLanguageValue === "string"
    ) {
      // Language-scoped overrides are rare for color theme but we
      // surface them as `workspaceFolder` when present.
      const value = inspection.workspaceFolderLanguageValue ?? inspection.workspaceLanguageValue;
      if (typeof value === "string" && differsFromGlobal(value)) {
        overrides.push({ scope: "workspaceFolder", value });
      }
    }
    return overrides;
  }

  /** Snapshot of the settings the app cares about, used at register time. */
  snapshot(): Record<string, string> {
    const config = vscode.workspace.getConfiguration();
    const settings: Record<string, string> = {};
    for (const key of [
      THEME_SETTING,
      "workbench.preferredDarkColorTheme",
      "workbench.preferredLightColorTheme",
    ]) {
      const value = config.get<string>(key);
      if (typeof value === "string") settings[key] = value;
    }
    return settings;
  }

  /**
   * VS Code exposes installed themes through the extensions API; each
   * extension contributes `contributes.themes[].label`.
   */
  isKnownTheme(name: string): boolean {
    for (const extension of vscode.extensions.all) {
      const themes = (extension.packageJSON as { contributes?: { themes?: Array<{ label?: string }> } })
        ?.contributes?.themes;
      if (!Array.isArray(themes)) continue;
      for (const theme of themes) {
        if (theme?.label === name) return true;
      }
    }
    return false;
  }

  private failed(request: ApplyThemeMessage, code: string, message: string): ApplyThemeAckMessage {
    return {
      type: "apply_theme_ack",
      protocolVersion: request.protocolVersion,
      id: request.id,
      status: "failed",
      requestedSetting: request.themeName,
      overrides: [],
      failure: { code, message },
    };
  }
}
