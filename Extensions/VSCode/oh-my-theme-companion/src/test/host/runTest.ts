import * as os from "os";
import * as path from "path";
import { promises as fs } from "fs";
import { runTests } from "@vscode/test-electron";

/**
 * Downloads a VS Code test host, launches it with the companion
 * extension pre-loaded, and runs the extension-host test suite. The
 * host reads a synthesised rendezvous file at
 * `OMT_RENDEZVOUS_PATH` instead of the production location so the
 * test does not touch the user's Application Support directory.
 */
async function main(): Promise<void> {
  try {
    const extensionDevelopmentPath = path.resolve(__dirname, "..", "..", "..");
    const extensionTestsPath = path.resolve(__dirname, "suite", "index.js");

    // Keep the rendezvous directory in /tmp so its socket paths fit
    // inside the 104-byte Unix-domain limit. VS Code also creates
    // sockets under the user data dir; that has to be short too.
    const shortId = Math.random().toString(36).slice(2, 10);
    const testRoot = path.join("/tmp", `omt-host-${shortId}`);
    await fs.mkdir(testRoot, { recursive: true, mode: 0o700 });
    const rendezvousPath = path.join(testRoot, "rendezvous.json");
    const userDataDir = path.join(testRoot, "ud");

    await runTests({
      extensionDevelopmentPath,
      extensionTestsPath,
      launchArgs: ["--disable-extensions", `--user-data-dir=${userDataDir}`],
      extensionTestsEnv: {
        OMT_TEST_ROOT: testRoot,
        // Point the extension at a rendezvous file the test never
        // creates so its auto-activation is a no-op. The test itself
        // drives `connect()` explicitly.
        OMT_RENDEZVOUS_PATH: path.join(testRoot, "unused-rendezvous.json"),
        OMT_TEST_RENDEZVOUS_PATH: rendezvousPath,
      },
    });
  } catch (err) {
    console.error("Failed to run tests", err);
    process.exit(1);
  }
}

void main();
