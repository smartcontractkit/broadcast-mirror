import os
import pytest


@pytest.fixture(scope="session")
def docker_compose_file(pytestconfig):
    return [
        os.path.join(str(pytestconfig.rootdir), "docker-compose.yml"),
        os.path.join(str(pytestconfig.rootdir), "tests", "docker-compose.tests.yml"),
    ]
