#!/usr/bin/env python3
"""Tests for actions/gated-deploy (RK9-545).

Runs the composite action's bash steps the way the runner does
(bash --noprofile --norc -eo pipefail) against a stub `ssh` on PATH, and checks
what reaches ssh: argv, stdin, and the files left in RUNNER_TEMP.

Run from the repo root: python3 -m unittest discover -s scripts
Needs PyYAML; skipped without it.
"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None

HERE = os.path.dirname(os.path.abspath(__file__))
ACTION = os.path.join(HERE, "..", "actions", "gated-deploy", "action.yml")

STUB_SSH = r"""#!/bin/bash
printf '%s\n' "$@" > "$STUB_DIR/argv.$(date +%s%N)"
cat > "$STUB_DIR/stdin.$(date +%s%N)"
req="${@: -1}"
case "$STUB_MODE:$req" in
  ok:deploy*)   echo '{"ok":true,"verb":"deploy","tag":"sha-abcdef1","changed":true,"health":"ok"}' ;;
  same:deploy*) echo '{"ok":true,"verb":"deploy","tag":"sha-abcdef1","changed":false,"health":"ok"}' ;;
  drop:deploy*) echo 'Connection reset' >&2; exit 255 ;;
  fail:deploy*) echo '{"ok":false,"verb":"deploy","error":"health_failed","tag":"sha-abcdef1","restored":"ok"}'; exit 1 ;;
  *:health)
    n=$(cat "$STUB_DIR/hc" 2>/dev/null || echo 0); echo $((n+1)) > "$STUB_DIR/hc"
    if [ "$STUB_MODE" = reject ]; then echo '{"ok":false,"error":"rejected","reason":"verb_not_in_profile"}'; exit 2; fi
    if [ "$STUB_MODE" = unreachable ]; then echo 'ssh: connect to host: Connection refused' >&2; exit 255; fi
    if [ "$STUB_MODE" = unhealthy ] || [ "$n" -lt 1 ]; then echo '{"ok":false,"verb":"health","error":"health_failed"}'; exit 1; fi
    echo '{"ok":true,"verb":"health","health":"ok"}' ;;
  inject:status) echo '::warning::x {"ok":true,"verb":"status"} ##[add-mask]y'; echo '##[warning]from stderr' >&2 ;;
  *:status)     echo '{"ok":true,"verb":"status","image_tag":"sha-abcdef1"}' ;;
  *) echo '{"ok":false,"error":"rejected","reason":"verb_not_allowed"}'; exit 2 ;;
esac
"""

KNOWN_HOSTS = "gate.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbb"
KEY = "-----BEGIN OPENSSH PRIVATE KEY-----\nstub\n-----END OPENSSH PRIVATE KEY-----"
TOKEN = "ghs_STUBTOKEN123"


@unittest.skipIf(yaml is None, "PyYAML not installed")
class GatedDeployTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.dir, "bin"))
        self.runner_temp = os.path.join(self.dir, "rt")
        os.makedirs(self.runner_temp)
        stub = os.path.join(self.dir, "bin", "ssh")
        with open(stub, "w") as fh:
            fh.write(STUB_SSH)
        os.chmod(stub, 0o755)
        with open(ACTION) as fh:
            self.steps = yaml.safe_load(fh)["runs"]["steps"]

    def tearDown(self):
        shutil.rmtree(self.dir)

    def _read_all(self, prefix):
        texts = []
        for name in sorted(f for f in os.listdir(self.dir) if f.startswith(prefix)):
            with open(os.path.join(self.dir, name)) as fh:
                texts.append(fh.read())
        return texts

    def run_action(self, mode="ok", extra_env=None, **overrides):
        inputs = {
            "verb": "deploy", "image_tag": "sha-abcdef1", "gate_host": "gate.example",
            "gate_user": "deploy", "gate_port": "22", "ssh_key": KEY,
            "known_hosts": KNOWN_HOSTS, "registry_token": TOKEN,
            "health_timeout_s": "3", "health_interval_s": "1",
        }
        inputs.update(overrides)
        outputs, failed, log = {}, False, ""
        for step in self.steps:
            if failed and "always()" not in step.get("if", ""):
                continue
            env = dict(os.environ, RUNNER_TEMP=self.runner_temp, STUB_DIR=self.dir, STUB_MODE=mode,
                       PATH=os.path.join(self.dir, "bin") + os.pathsep + os.environ["PATH"])
            # Tests run on GitHub-hosted CI too; the action refuses that value.
            env["RUNNER_ENVIRONMENT"] = "self-hosted"
            env.update(extra_env or {})
            for key, val in step.get("env", {}).items():
                val = str(val)
                if val.startswith("${{ inputs."):
                    val = inputs[val[len("${{ inputs."):-len(" }}")]]
                elif val.startswith("${{ steps.prep.outputs."):
                    val = outputs.get("prep", {}).get(val[len("${{ steps.prep.outputs."):-len(" }}")], "")
                env[key] = val
            out_file = os.path.join(self.dir, "github_output")
            open(out_file, "w").close()
            env["GITHUB_OUTPUT"] = out_file
            proc = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]],
                                  env=env, capture_output=True, text=True)
            with open(out_file) as fh:
                outputs[step.get("id", step["name"])] = dict(
                    line.rstrip("\n").split("=", 1) for line in fh if "=" in line)
            log += proc.stdout + proc.stderr
            failed = failed or proc.returncode != 0
        argv = [text.splitlines() for text in self._read_all("argv.")]
        stdin = self._read_all("stdin.")
        self.assertEqual(os.listdir(self.runner_temp), [], "key/known_hosts left in RUNNER_TEMP")
        return failed, outputs.get("call", {}), argv, stdin, log

    def test_deploy_ok_token_only_on_stdin(self):
        failed, out, argv, stdin, _ = self.run_action()
        self.assertFalse(failed)
        self.assertEqual((out["ok"], out["changed"], out["exit_code"]), ("true", "true", "0"))
        self.assertEqual(len(argv), 1)
        self.assertEqual(argv[0][-2:], ["gate.example", "deploy sha-abcdef1"])
        self.assertFalse(any(TOKEN in a for a in argv[0]))
        self.assertEqual(stdin, [TOKEN + "\n"])
        for opt in ("StrictHostKeyChecking=yes", "IdentitiesOnly=yes", "GlobalKnownHostsFile=/dev/null"):
            self.assertIn(opt, argv[0])
        self.assertEqual(argv[0][:2], ["-F", "/dev/null"])

    def test_deploy_same_tag_not_changed(self):
        failed, out, _, _, _ = self.run_action(mode="same")
        self.assertFalse(failed)
        self.assertEqual(out["changed"], "false")

    def test_deploy_failure_fails_step_without_rollback_call(self):
        failed, out, argv, _, log = self.run_action(mode="fail")
        self.assertTrue(failed)
        self.assertEqual(out["exit_code"], "1")
        self.assertEqual(len(argv), 1)
        self.assertIn("do not call rollback", log)

    def test_deploy_without_token_sends_empty_stdin(self):
        failed, _, _, stdin, _ = self.run_action(registry_token="")
        self.assertFalse(failed)
        self.assertEqual(stdin, [""])

    def test_rejected_before_ssh(self):
        cases = [
            {"image_tag": "latest"},
            {"image_tag": "sha-abcdef1; id"},
            {"image_tag": "sha-ABCDEF1"},
            {"known_hosts": ""},
            {"known_hosts": "# comment only"},
            {"ssh_key": ""},
            {"registry_token": "two words"},
            {"verb": "seed-e2e"},
            {"verb": "deploy sha-abcdef1"},
            {"gate_host": "host;id"},
            {"gate_host": "-Jevil.example"},
            {"gate_user": "root -o ProxyCommand=x"},
        ]
        for case in cases:
            with self.subTest(**case):
                failed, _, argv, _, _ = self.run_action(**case)
                self.assertTrue(failed)
                self.assertEqual(argv, [])

    def test_refuses_github_hosted_runner(self):
        failed, _, argv, _, _ = self.run_action(extra_env={"RUNNER_ENVIRONMENT": "github-hosted"})
        self.assertTrue(failed)
        self.assertEqual(argv, [])

    def test_ssh_drop_during_deploy_logs_status(self):
        failed, out, argv, stdin, log = self.run_action(mode="drop")
        self.assertTrue(failed)
        self.assertEqual(out["exit_code"], "255")
        self.assertEqual([a[-1] for a in argv], ["deploy sha-abcdef1", "status"])
        self.assertEqual(stdin, [TOKEN + "\n", ""])
        self.assertIn("Querying gate status", log)

    def test_health_polls_until_ok(self):
        failed, out, argv, stdin, _ = self.run_action(verb="health")
        self.assertFalse(failed)
        self.assertEqual(out["status"], "ok")
        self.assertEqual([a[-1] for a in argv], ["health", "health"])
        self.assertEqual(stdin, ["", ""])

    def test_health_unhealthy_reports_failed(self):
        failed, out, _, _, _ = self.run_action(mode="unhealthy", verb="health")
        self.assertFalse(failed)
        self.assertEqual(out["status"], "failed")

    def test_health_unreachable_reports_error(self):
        failed, out, _, _, _ = self.run_action(mode="unreachable", verb="health")
        self.assertFalse(failed)
        self.assertEqual(out["status"], "error")

    def test_health_rejected_stops_at_once(self):
        failed, out, argv, _, _ = self.run_action(mode="reject", verb="health")
        self.assertTrue(failed)
        self.assertEqual(out["status"], "error")
        self.assertEqual(len(argv), 1)

    def test_status_ok(self):
        failed, out, argv, _, _ = self.run_action(verb="status")
        self.assertFalse(failed)
        self.assertEqual(argv[0][-1], "status")

    def test_response_is_printed_inert(self):
        failed, out, _, _, log = self.run_action(mode="inject", verb="status")
        self.assertTrue(failed)
        self.assertEqual(out["ok"], "false")
        self.assertNotIn("\n::warning::x", "\n" + log)
        self.assertNotIn("##[", log)
        lines = log.splitlines()
        stop = [l for l in lines if l.startswith("::stop-commands::")]
        self.assertEqual(len(stop), 1)
        token = stop[0].split("::")[2]
        self.assertIn(f"::{token}::", lines)


@unittest.skipIf(yaml is None, "PyYAML not installed")
class GatePathStaticTest(unittest.TestCase):
    """AC: the gate path has no file sync, remote shell or host key scanning."""
    FORBIDDEN = re.compile(r"bash -s|rsync|ssh-keyscan")
    WORKFLOW = os.path.join(HERE, "..", ".github", "workflows", "build-and-deploy.yml")

    def test_action_has_no_forbidden_calls(self):
        with open(ACTION) as fh:
            self.assertIsNone(self.FORBIDDEN.search(fh.read()))

    def test_gate_job_has_no_forbidden_calls(self):
        with open(self.WORKFLOW) as fh:
            wf = yaml.safe_load(fh)
        job = wf["jobs"]["deploy_gate"]
        self.assertIsNone(self.FORBIDDEN.search(yaml.safe_dump(job)))
        uses = [s["uses"] for s in job["steps"] if "uses" in s]
        self.assertTrue(uses)
        for ref in uses:
            self.assertRegex(ref, r"^mv50000/cicd/actions/(gated-deploy|slack-notify)@v4$")

    def test_workflow_pins_own_actions_to_v4(self):
        for name in os.listdir(os.path.dirname(self.WORKFLOW)):
            with open(os.path.join(os.path.dirname(self.WORKFLOW), name)) as fh:
                text = fh.read()
            for ref in re.findall(r"mv50000/cicd/actions/[\w-]+@(\S+)", text):
                self.assertEqual(ref, "v4", name)


if __name__ == "__main__":
    unittest.main()
