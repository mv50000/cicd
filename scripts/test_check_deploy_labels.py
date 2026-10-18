#!/usr/bin/env python3
"""Tests for check-deploy-labels.py (RK9-545).

Run from the repo root: python3 -m unittest discover -s scripts
or from scripts/:       python3 -m unittest
"""
import contextlib
import importlib.util
import io
import os
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "check_deploy_labels", os.path.join(HERE, "check-deploy-labels.py"))
cdl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cdl)


def reusable_call(transport=None, runner_label=None):
    lines = [
        "jobs:",
        "  deploy:",
        "    uses: mv50000/cicd/.github/workflows/build-and-deploy.yml@v4",
        "    with:",
        "      company: demo",
        "      deploy_host: ${{ secrets.DEPLOY_HOST }}",
    ]
    if transport is not None:
        lines.append(f"      deploy_transport: {transport}")
    if runner_label is not None:
        lines.append(f"      runner_label: {runner_label}")
    return "\n".join(lines) + "\n"


def gated_action_job(runs_on):
    return textwrap.dedent(f"""\
        jobs:
          gate:
            runs-on: {runs_on}
            steps:
              - uses: mv50000/cicd/actions/gated-deploy@v4
                with:
                  verb: status
        """)


class GuardTest(unittest.TestCase):
    def run_guard(self, workflow, name="deploy-dev.yml"):
        with tempfile.TemporaryDirectory() as repo:
            wfdir = os.path.join(repo, ".github", "workflows")
            os.makedirs(wfdir)
            with open(os.path.join(wfdir, name), "w") as fh:
                fh.write(workflow)
            out = io.StringIO()
            old_argv = sys.argv
            sys.argv = ["check-deploy-labels.py", repo]
            try:
                with contextlib.redirect_stdout(out):
                    rc = cdl.main()
            finally:
                sys.argv = old_argv
            return rc, out.getvalue()

    def assertOk(self, workflow):
        rc, out = self.run_guard(workflow)
        self.assertEqual(rc, 0, out)

    def assertViolation(self, workflow, needle=None):
        rc, out = self.run_guard(workflow)
        self.assertEqual(rc, 1, out)
        if needle:
            self.assertIn(needle, out)

    # gate mode, reusable
    def test_gate_lan_deploy_ok(self):
        self.assertOk(reusable_call("gate", "lan-deploy"))

    def test_gate_lan_deploy_suffix_ok(self):
        self.assertOk(reusable_call("gate", "lan-deploy-qua"))

    def test_gate_quoted_label_ok(self):
        self.assertOk(reusable_call("'gate'", '"lan-deploy"'))

    def test_gate_missing_label_violation(self):
        self.assertViolation(reusable_call("gate"), "missing")

    def test_gate_self_hosted_violation(self):
        self.assertViolation(reusable_call("gate", "self-hosted"), "'self-hosted'")

    def test_gate_paperclip_violation(self):
        self.assertViolation(reusable_call("gate", "paperclip"), "'paperclip'")

    def test_gate_docker_violation(self):
        self.assertViolation(reusable_call("gate", "docker"), "'docker'")

    def test_gate_cloud_violation(self):
        self.assertViolation(reusable_call("gate", "blacksmith-4vcpu-ubuntu-2404"))
        self.assertViolation(reusable_call("gate", "ubuntu-latest"))

    def test_gate_expression_violation(self):
        self.assertViolation(reusable_call("gate", "${{ vars.DEPLOY_RUNNER }}"), "non-literal")

    def test_gate_lookalike_violation(self):
        self.assertViolation(reusable_call("gate", "lan-deployer"))
        self.assertViolation(reusable_call("gate", "x-lan-deploy"))

    # ssh mode keeps the RK9-37 behaviour
    def test_ssh_docker_ok(self):
        self.assertOk(reusable_call(None, "docker"))
        self.assertOk(reusable_call("ssh", "docker"))

    def test_ssh_default_label_ok(self):
        self.assertOk(reusable_call())

    def test_ssh_cloud_violation(self):
        self.assertViolation(reusable_call(None, "blacksmith-4vcpu-ubuntu-2404"), "cloud runner_label")

    def test_ssh_job_on_cloud_violation(self):
        self.assertViolation(textwrap.dedent("""\
            jobs:
              deploy:
                runs-on: ubuntu-latest
                steps:
                  - run: ssh deploy@host true
            """))

    def test_cloud_build_job_ok(self):
        self.assertOk(textwrap.dedent("""\
            jobs:
              build:
                runs-on: blacksmith-4vcpu-ubuntu-2404
                steps:
                  - run: docker build .
            """))

    # gate mode, direct action use
    def test_gated_action_lan_deploy_ok(self):
        self.assertOk(gated_action_job("[self-hosted, lan-deploy]"))
        self.assertOk(gated_action_job('["self-hosted", "lan-deploy"]'))

    def test_gated_action_block_list_ok(self):
        self.assertOk(textwrap.dedent("""\
            jobs:
              gate:
                runs-on:
                  - self-hosted
                  - lan-deploy
                steps:
                  - uses: mv50000/cicd/actions/gated-deploy@v4
            """))

    def test_gated_action_self_hosted_violation(self):
        self.assertViolation(gated_action_job("self-hosted"), "gated-deploy")
        self.assertViolation(gated_action_job("[self-hosted, paperclip]"), "gated-deploy")

    def test_gated_action_cloud_violation(self):
        self.assertViolation(gated_action_job("ubuntu-latest"), "gated-deploy")

    def test_no_workflows(self):
        with tempfile.TemporaryDirectory() as repo:
            out = io.StringIO()
            old_argv = sys.argv
            sys.argv = ["check-deploy-labels.py", repo]
            try:
                with contextlib.redirect_stdout(out):
                    self.assertEqual(cdl.main(), 0)
            finally:
                sys.argv = old_argv


if __name__ == "__main__":
    unittest.main()
