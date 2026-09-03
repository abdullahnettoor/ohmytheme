import * as vscode from "vscode";
import {
  ApplyThemeAckMessage,
  ApplyThemeMessage,
  OverrideEntry,
} from "./protocol";

const THEME_SETTING = "workbench.colorTheme";

export interface ThemeInspection {
  configuredSetting?: string;
  effectiveSetting?: string;
  overrides: OverrideEntry[];
}

/**
 * Reads and updates the profile-level color theme through VS Code's
 * configuration API. Writes use ConfigurationTarget.Global and are guarded
 * by the caller's expected configured value.
 */
export class ThemeService {
  inspect(): ThemeInspection {
    const configuration = vscode.workspace.getConfiguration();
    const settingInspection = configuration.inspect<string>(THEME_SETTING);
    const configuredSetting = this.stringValue(settingInspection?.globalValue);
    const effectiveSetting = this.stringValue(configuration.get<string>(THEME_SETTING));

    return {
      ...(configuredSetting !== undefined ? { configuredSetting } : {}),
      ...(effectiveSetting !== undefined ? { effectiveSetting } : {}),
      overrides: this.collectOverridesFrom(settingInspection, effectiveSetting),
    };
  }

  async apply(request: ApplyThemeMessage): Promise<ApplyThemeAckMessage> {
    if (request.target !== "global") {
      return this.failed(
        request,
        undefined,
        this.inspect(),
        "unsupported_target",
        `target '${request.target}' not supported`,
      );
    }

    if (request.themeName !== null && !this.isKnownTheme(request.themeName)) {
      const inspection = this.inspect();
      return {
        type: "apply_theme_ack",
        protocolVersion: request.protocolVersion,
        id: request.id,
        status: "unsupported_theme",
        requestedSetting: request.themeName,
        ...this.settingFields(inspection.configuredSetting, inspection),
      };
    }

    const configuration = vscode.workspace.getConfiguration();
    const previousSetting = this.stringValue(
      configuration.inspect<string>(THEME_SETTING)?.globalValue,
    );

    if (!this.matchesExpected(previousSetting, request.expectedSetting)) {
      const inspection = this.inspect();
      return {
        type: "apply_theme_ack",
        protocolVersion: request.protocolVersion,
        id: request.id,
        status: "conflicted",
        requestedSetting: request.themeName,
        ...this.settingFields(previousSetting, inspection),
      };
    }

    try {
      await configuration.update(
        THEME_SETTING,
        request.themeName === null ? undefined : request.themeName,
        vscode.ConfigurationTarget.Global,
      );
    } catch (error) {
      return this.failed(
        request,
        previousSetting,
        this.inspect(),
        "update_threw",
        error instanceof Error ? error.message : String(error),
      );
    }

    const inspection = this.inspect();
    const configuredMatches = this.matchesExpected(
      inspection.configuredSetting,
      request.themeName,
    );
    if (!configuredMatches) {
      return this.failed(
        request,
        previousSetting,
        inspection,
        "verification_mismatch",
        "The configured global theme did not match the requested setting after update.",
      );
    }

    const isActive =
      request.themeName === null
        ? inspection.overrides.length === 0
        : inspection.effectiveSetting === request.themeName;
    if (!isActive && inspection.overrides.length === 0) {
      return this.failed(
        request,
        previousSetting,
        inspection,
        "verification_mismatch",
        "The effective theme differs from the requested setting without a reported override.",
      );
    }
    const status = isActive ? "applied" : "overridden";

    return {
      type: "apply_theme_ack",
      protocolVersion: request.protocolVersion,
      id: request.id,
      status,
      requestedSetting: request.themeName,
      ...this.settingFields(previousSetting, inspection),
    };
  }

  /** Return the currently effective `workbench.colorTheme`. */
  effectiveTheme(): string | undefined {
    return this.inspect().effectiveSetting;
  }

  /** Enumerate settings that take precedence over the configured global value. */
  collectOverrides(): OverrideEntry[] {
    return this.inspect().overrides;
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

  private collectOverridesFrom(
    inspection: ReturnType<vscode.WorkspaceConfiguration["inspect"]>,
    effectiveSetting: string | undefined,
  ): OverrideEntry[] {
    if (!inspection) return [];

    const globalValue = this.stringValue(inspection.globalValue);
    const differsFromGlobal = (value: string): boolean =>
      globalValue === undefined || value !== globalValue;
    const overrides: OverrideEntry[] = [];

    if (typeof inspection.workspaceValue === "string" && differsFromGlobal(inspection.workspaceValue)) {
      overrides.push({ scope: "workspace", value: inspection.workspaceValue });
    }
    if (
      typeof inspection.workspaceFolderValue === "string" &&
      differsFromGlobal(inspection.workspaceFolderValue)
    ) {
      const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
      overrides.push({
        scope: "workspaceFolder",
        ...(folder !== undefined ? { folder } : {}),
        value: inspection.workspaceFolderValue,
      });
    }

    const languageValue =
      inspection.workspaceFolderLanguageValue ?? inspection.workspaceLanguageValue;
    if (typeof languageValue === "string" && differsFromGlobal(languageValue)) {
      overrides.push({ scope: "workspaceFolder", value: languageValue });
    }

    const baseline = globalValue ?? this.stringValue(inspection.defaultValue);
    const effectiveIsAlreadyExplained = overrides.some(
      (override) => override.value === effectiveSetting,
    );
    if (
      vscode.env.remoteName !== undefined &&
      effectiveSetting !== undefined &&
      effectiveSetting !== baseline &&
      !effectiveIsAlreadyExplained
    ) {
      overrides.push({ scope: "remote", value: effectiveSetting });
    }

    // `inspect` exposes values at every scope, including lower-precedence values
    // that are not active. Report only entries that explain the effective result.
    return overrides.filter((override) => override.value === effectiveSetting);
  }

  private failed(
    request: ApplyThemeMessage,
    previousSetting: string | undefined,
    inspection: ThemeInspection,
    code: string,
    message: string,
  ): ApplyThemeAckMessage {
    return {
      type: "apply_theme_ack",
      protocolVersion: request.protocolVersion,
      id: request.id,
      status: "failed",
      requestedSetting: request.themeName,
      ...this.settingFields(previousSetting, inspection),
      failure: { code, message },
    };
  }

  private settingFields(
    previousSetting: string | undefined,
    inspection: ThemeInspection,
  ): Pick<
    ApplyThemeAckMessage,
    "previousSetting" | "configuredSetting" | "effectiveSetting" | "overrides"
  > {
    return {
      ...(previousSetting !== undefined ? { previousSetting } : {}),
      ...(inspection.configuredSetting !== undefined
        ? { configuredSetting: inspection.configuredSetting }
        : {}),
      ...(inspection.effectiveSetting !== undefined
        ? { effectiveSetting: inspection.effectiveSetting }
        : {}),
      overrides: inspection.overrides,
    };
  }

  private matchesExpected(actual: string | undefined, expected: string | null): boolean {
    return expected === null ? actual === undefined : actual === expected;
  }

  private stringValue(value: unknown): string | undefined {
    return typeof value === "string" ? value : undefined;
  }
}
