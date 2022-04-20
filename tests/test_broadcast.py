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
def broadcast_mirror_service(docker_ip, docker_services):
    """Ensure that HTTP service is up and responsive."""
    port = docker_services.port_for("broadcast-mirror", 8080)
    url = "http://{}:{}".format(docker_ip, port)
    docker_services.wait_until_responsive(
        timeout=10.0, pause=1, check=lambda: is_responsive(url)
    )
    return url

@pytest.fixture(scope="session")
def broadcast_mirror_multichain_service(docker_ip, docker_services):
    """Ensure that HTTP service is up and responsive."""
    port = docker_services.port_for("broadcast-mirror-multichain", 8080)
    url = "http://{}:{}".format(docker_ip, port)
    docker_services.wait_until_responsive(
        timeout=10.0, pause=1, check=lambda: is_responsive(url)
    )
    return url


def test_invalid_auth(broadcast_mirror_service):
    r = requests.get(
        broadcast_mirror_service, auth=requests.auth.HTTPBasicAuth("invalid", "account")
    )
    assert r.status_code == 401


def test_invalid_json(broadcast_mirror_service):
    """Handle non-JSON POST data."""
    r = requests.post(broadcast_mirror_service, data="invalid", auth=sample_auth)
    assert r.status_code == 400


def test_unsupported_method(broadcast_mirror_service):
    """Handle misc RPC methods."""
    r = requests.post(
        broadcast_mirror_service,
        json={
            "jsonrpc": "2.0",
            "method": "eth_doSomething",
            "params": ["0x1234"],
            "id": 1,
        },
        auth=sample_auth,
    )
    assert r.status_code == 400
    assert r.json()["id"] == 1
    assert r.json()["error"]["message"] == "Unsupported RPC call"


def test_empty_sendRawTxn(broadcast_mirror_service):
    """Handle malformed method params."""
    r = requests.post(
        broadcast_mirror_service,
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


def test_receive_request(broadcast_mirror_service):
    """Ensure mirroring works"""
    r = requests.post(
        broadcast_mirror_service,
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

def test_receive_request_multichain(broadcast_mirror_multichain_service):
    """Ensure mirroring works"""
    r = requests.post(
        broadcast_mirror_multichain_service,
        json={
            "jsonrpc": "2.0",
            "method": "eth_sendRawTransaction",
            "params": ["0x12345678"],
            "id": 5,
        },
        auth=sample_auth,
        params={"chain_id": "Testing"},
    )
    assert r.status_code == 200
    assert r.json()["id"] == 5
    assert r.json()["result"] == ""

    r = requests.post(
        broadcast_mirror_multichain_service,
        json={
            "jsonrpc": "2.0",
            "method": "eth_sendRawTransaction",
            "params": ["0x12345678"],
            "id": 55,
        },
        auth=sample_auth,
        params={"chain_id": "ChainedTesting"},
    )
    assert r.status_code == 200
    assert r.json()["id"] == 55
    assert r.json()["result"] == ""


def test_invalid_request_multichain(broadcast_mirror_multichain_service):
    """Test missing chain_id"""
    r = requests.post(
        broadcast_mirror_multichain_service,
        json={
            "jsonrpc": "2.0",
            "method": "eth_sendRawTransaction",
            "params": ["0x12345678"],
            "id": 56,
        },
        auth=sample_auth,
    )
    assert r.status_code == 400


def test_multi_post(broadcast_mirror_service):
    """Ensure mirroring works, w/multiple inputs"""
    r = requests.post(
        broadcast_mirror_service,
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


def test_multi_post_malformed(broadcast_mirror_service):
    """Handle malformed method params."""
    r = requests.post(
        broadcast_mirror_service,
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


def test_multi_post_malformed_okay(broadcast_mirror_service):
    """Handle malformed method params. Service returns status of _last_ txn in request."""
    r = requests.post(
        broadcast_mirror_service,
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


def test_multi_post_mixed(broadcast_mirror_service):
    """Handle mixed success/error."""
    r = requests.post(
        broadcast_mirror_service,
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

def test_chainid(broadcast_mirror_multichain_service):
    """Ensure chainID response is correct"""
    r = requests.post(
        broadcast_mirror_multichain_service,
        json={
            "jsonrpc": "2.0",
            "method": "eth_chainId",
            "params": [],
            "id": 100,
        },
        auth=sample_auth,
        params={"chain_id": "56"},
    )
    assert r.status_code == 200
    assert r.json()["id"] == 100
    assert r.json()["result"] == "0x38"

def test_clientversion(broadcast_mirror_multichain_service):
    """Ensure clientVersion response is correct"""
    r = requests.post(
        broadcast_mirror_multichain_service,
        json={
            "jsonrpc": "2.0",
            "method": "web3_clientVersion",
            "params": [],
            "id": 101,
        },
        auth=sample_auth,
        params={"chain_id": "56"},
    )
    assert r.status_code == 200
    assert r.json()["id"] == 101
    assert r.json()["result"].startswith("BroadcastMirror/v")
