import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

let skipNextIdle = false;

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
    // The child's "error" handler above does NOT cover the stdin STREAM. If the child
    // exits (or closes fd 0) before this input is dispatched, the write fails EPIPE, and
    // an unhandled "error" event on a stream is a hard process crash in Node - it would
    // take the whole plugin host down at session idle, which is exactly when the turn-end
    // guard runs. Every spawn in this plugin goes through here, so this one listener
    // covers the guard, the watcher arm, and git. The input is advisory and the child's
    // EXIT CODE is what we act on, so a failed write is nothing to report: swallow it and
    // let "close" deliver the verdict.
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

async function letWatchArmRun(sessionID, client) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, client);
  return status === "armed" || status === "wake" || status === "failed";
}

export const FmPrimaryTurnendGuard = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;

      if (skipNextIdle) {
        skipNextIdle = false;
        return;
      }

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;

      if (await letWatchArmRun(sessionID, client)) return;

      const result = await runGuard(root);
      if (result.code !== 2) return;

      try {
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [
              {
                type: "text",
                text:
                  "TURN WOULD END BLIND - supervision is off. " +
                  "Resume supervision according to the session-start operating block before ending the turn.\n\n" +
                  result.stderr,
              },
            ],
          },
        });
        skipNextIdle = true;
      } catch {
        skipNextIdle = false;
      }
    },
  };
};
