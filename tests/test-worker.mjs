import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import worker, { launcher } from "../worker.mjs";

test("entry uses HTTPS 8443; archive stays on the static asset binding", async () => {
  const request = new Request("https://download.example/reinstall.sh");
  const response = await worker.fetch(request, {});
  assert.equal(response.status, 200);
  assert.match(await response.text(), /https:\/\/download\.example:8443\/reinstall\.tar\.gz/);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal((await worker.fetch(new Request(request.url, { method: "POST" }), {})).status, 405);
  assert.equal(await (await worker.fetch(new Request(request.url, { method: "HEAD" }), {})).text(), "");
  const assets = { fetch: () => new Response("archive") };
  assert.equal(await (await worker.fetch(new Request("https://download.example/reinstall.tar.gz"), { ASSETS: assets })).text(), "archive");
});

function run(mode) {
  const root = mkdtempSync(join(tmpdir(), "po0-download-"));
  try {
    const source = join(root, "source");
    const caller = join(root, "caller");
    const temp = join(root, "temporary");
    mkdirSync(join(source, "reinstall-Po0"), { recursive: true });
    mkdirSync(caller);
    mkdirSync(temp);
    writeFileSync(join(caller, "key"), "fixture");
    writeFileSync(join(source, "reinstall-Po0", "reinstall.sh"), `#!/usr/bin/env bash
test -f ./key || exit 81
printf '%s\\0' "$@" >"$TEST_RESULT"
read -r answer
printf '%s\\n' "$answer"
umask
exit 7
`);
    const archive = join(root, "source.tar.gz");
    assert.equal(spawnSync("tar", ["-czf", archive, "-C", source, "reinstall-Po0"]).status, 0);
    if (mode === "corrupt") writeFileSync(archive, "broken archive");
    if (mode === "missing") {
      rmSync(join(source, "reinstall-Po0", "reinstall.sh"));
      assert.equal(spawnSync("tar", ["-czf", archive, "-C", source, "reinstall-Po0"]).status, 0);
    }
    const script = launcher("https://download.example:8443");
    writeFileSync(join(caller, "reinstall.sh"), script);
    const toShell = (path) => path.replaceAll("\\", "/");
    const env = { ...process.env, MODE: mode, FIXTURE: toShell(archive),
      TMPDIR: toShell(temp), TEST_RESULT: toShell(join(root, "result")) };
    const shell = process.env.PO0_TEST_SHELL || "bash";
    const args = ["debian", "--ssh-key", "./key", "space here", "literal$(nope)", ""];
    const result = spawnSync(shell, ["-c", `
umask 027
curl() { [ "$MODE" != fallback ] && [ "$MODE" != fail ] || return 7; for dest do :; done; cp "$FIXTURE" "$dest"; }
wget() { [ "$MODE" != fail ] || return 8; cp "$FIXTURE" "$2"; }
export -f curl wget
exec bash ./reinstall.sh "$@"
`, "fixture", ...args], { cwd: caller, env, input: "interactive answer\n", encoding: "utf8" });
    if (["curl", "fallback"].includes(mode)) {
      assert.equal(result.status, 7, result.stderr);
      assert.equal(readFileSync(join(root, "result"), "utf8"), args.join("\0") + "\0");
      assert.equal(result.stdout, "interactive answer\n0027\n");
      assert.equal(readFileSync(join(caller, "reinstall.sh"), "utf8"), script);
      assert.equal(readdirSync(temp).length, 1);
    } else {
      assert.notEqual(result.status, 0);
      assert.notEqual(result.status, 7);
      assert.equal(readdirSync(temp).length, 0);
      assert.ok(!readdirSync(root).includes("result"));
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("curl download preserves arguments, stdin, cwd, umask and installer status", () => run("curl"));
test("wget fallback preserves installer behavior", () => run("fallback"));
test("download failure, corrupt archive and missing installer stop execution", () => {
  for (const mode of ["fail", "corrupt", "missing"]) run(mode);
});
