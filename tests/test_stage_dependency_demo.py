"""Intentional failure used to demonstrate that build-push and deploy are skipped when test fails."""


def test_stage_dependency_demo():
    assert False, "intentional failure: demonstrates needs between jobs"
