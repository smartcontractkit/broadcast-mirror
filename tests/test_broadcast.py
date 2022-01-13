import pytest
import requests

sample_auth = requests.auth.HTTPBasicAuth("username", "password")


def is_responsive(url):
    try:
        response = requests.get(url, auth=sample_auth)
        if response.status_code == 200:
            return True
    except requests.ConnectionError:
        return False


@pytest.fixture(scope="session")
def http_service(docker_ip, docker_services):
    """Ensure that HTTP service is up and responsive."""
    port = docker_services.port_for("broadcast-mirror", 8080)
    url = "http://{}:{}".format(docker_ip, port)
    docker_services.wait_until_responsive(
        timeout=10.0, pause=1, check=lambda: is_responsive(url)
    )
    return url


def test_invalid_auth(http_service):
    r = requests.get(
        http_service, auth=requests.auth.HTTPBasicAuth("invalid", "account")
    )
    assert r.status_code == 401


def test_invalid_json(http_service):
    """Handle non-JSON POST data."""
    r = requests.post(http_service, data="invalid", auth=sample_auth)
    assert r.status_code == 400


def test_unsupported_method(http_service):
    """Handle misc RPC methods."""
    r = requests.post(
        http_service,
        json={
            "jsonrpc": "2.0",
            "method": "eth_doSomething",
            "params": ["0x1234"],
            "id": 1,
        },
        auth=sample_auth,
    )
    assert r.status_code == 200
    assert r.json()["id"] == 1
    assert r.json()["result"] == ""


def test_empty_sendRawTxn(http_service):
    """Handle malformed method params."""
    r = requests.post(
        http_service,
        json={
            "jsonrpc": "2.0",
            "method": "eth_sendRawTransaction",
            "params": [""],
            "id": 4,
        },
        auth=sample_auth,
    )
    assert r.status_code == 400
    assert r.json()["id"] == 4
    assert r.json()["error"]["code"] == -32000


def test_receive_request(http_service):
    """Ensure mirroring works"""
    r = requests.post(
        http_service,
        json={
            "jsonrpc": "2.0",
            "method": "eth_sendRawTransaction",
            "params": ["0x12345678"],
            "id": 5,
        },
        auth=sample_auth,
    )
    assert r.status_code == 200
    assert r.json()["id"] == 5
    assert r.json()["result"] == ""


def test_multi_post(http_service):
    """Ensure mirroring works, w/multiple inputs"""
    r = requests.post(
        http_service,
        json=[
            {
                "jsonrpc": "2.0",
                "method": "eth_sendRawTransaction",
                "params": ["0x12345678"],
                "id": 7,
            },
            {
                "jsonrpc": "2.0",
                "method": "eth_sendRawTransaction",
                "params": ["0x87654321"],
                "id": 8,
            },
        ],
        auth=sample_auth,
    )
    assert r.status_code == 200
    assert r.json()["id"] == 7
    assert r.json()["result"] == ""


def test_multi_post_malformed(http_service):
    """Handle malformed method params."""
    r = requests.post(
        http_service,
        json=[
            {
                "jsonrpc": "2.0",
                "method": "eth_sendRawTransaction",
                "params": [""],
                "id": 9,
            },
            {
                "jsonrpc": "2.0",
                "method": "eth_sendRawTransaction",
                "params": [""],
                "id": 10,
            },
        ],
        auth=sample_auth,
    )
    assert r.status_code == 400
    assert r.json()["id"] == 10
    assert r.json()["error"]["code"] == -32000


def test_multi_post_malformed_okay(http_service):
    """Handle malformed method params. Service returns status of _last_ txn in request."""
    r = requests.post(
        http_service,
        json=[
            {
                "jsonrpc": "2.0",
                "method": "eth_sendRawTransaction",
                "params": ["0x12345678"],
                "id": 11,
            },
            {
                "jsonrpc": "2.0",
                "method": "eth_sendRawTransaction",
                "params": [""],
                "id": 12,
            },
        ],
        auth=sample_auth,
    )
    assert r.status_code == 400
    assert r.json()["id"] == 12
    assert r.json()["error"]["code"] == -32000


def test_multi_post_mixed(http_service):
    """Handle mixed success/error."""
    r = requests.post(
        http_service,
        json=[
            {
                "jsonrpc": "2.0",
                "method": "eth_sendRawTransaction",
                "params": [""],
                "id": 13,
            },
            {
                "jsonrpc": "2.0",
                "method": "eth_sendRawTransaction",
                "params": ["0x123456"],
                "id": 14,
            },
        ],
        auth=sample_auth,
    )
    assert r.status_code == 400
    assert r.json()["id"] == 13
    assert r.json()["error"]["code"] == -32000
