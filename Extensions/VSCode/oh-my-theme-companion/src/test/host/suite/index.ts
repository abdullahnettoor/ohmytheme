import * as path from "path";
import Mocha from "mocha";
import { globSync } from "glob";

export function run(): Promise<void> {
  const mocha = new Mocha({
    ui: "bdd",
    color: true,
    timeout: 30_000,
  });
  const testsRoot = path.resolve(__dirname);
  const files = globSync("**/*.test.js", { cwd: testsRoot });
  for (const f of files) mocha.addFile(path.resolve(testsRoot, f));

  return new Promise((resolve, reject) => {
    try {
      mocha.run((failures) => {
        if (failures > 0) reject(new Error(`${failures} tests failed.`));
        else resolve();
      });
    } catch (err) {
      reject(err);
    }
  });
}
