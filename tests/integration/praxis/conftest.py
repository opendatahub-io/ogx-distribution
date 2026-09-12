import os
import pytest
import requests


def pytest_addoption(parser):
    parser.addoption(
        "--ogx-url",
        action="store",
        default=os.environ.get("OGX_URL", "http://localhost:8000"),
        help="Base URL for the OGX server with Praxis proxy enabled",
    )


@pytest.fixture(scope="session")
def ogx_url(request):
    url = request.config.getoption("--ogx-url").rstrip("/")
    if not url.endswith("/v1"):
        url = f"{url}/v1"
    return url


@pytest.fixture(autouse=True)
def check_server_reachable(ogx_url):
    """Skip test if the OGX server is not running or unreachable."""
    try:
        requests.get(f"{ogx_url}/health", timeout=2)
    except Exception:
        pytest.skip(f"OGX server at {ogx_url} is not running or unreachable")


class PraxisClient:
    """HTTP client wrapper for Praxis / OGX API calls with tenant and user headers."""

    def __init__(
        self, base_url: str, user_id: str | None = None, tenant_id: str | None = None
    ):
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        if user_id:
            self.session.headers["x-user-id"] = user_id
        if tenant_id:
            self.session.headers["x-tenant-id"] = tenant_id

    def get(self, path: str, **kwargs):
        url = f"{self.base_url}/{path.lstrip('/')}"
        return self.session.get(url, **kwargs)

    def post(self, path: str, **kwargs):
        url = f"{self.base_url}/{path.lstrip('/')}"
        return self.session.post(url, **kwargs)

    def delete(self, path: str, **kwargs):
        url = f"{self.base_url}/{path.lstrip('/')}"
        return self.session.delete(url, **kwargs)

    def upload_file(self, filename: str, content: bytes, purpose: str = "assistants"):
        files = {"file": (filename, content, "text/plain")}
        data = {"purpose": purpose}
        return self.post("/files", files=files, data=data)


@pytest.fixture
def tenant_a_client(ogx_url):
    """HTTP client for User A in Tenant A."""
    return PraxisClient(base_url=ogx_url, user_id="user-a", tenant_id="tenant-a")


@pytest.fixture
def tenant_b_client(ogx_url):
    """HTTP client for User B in Tenant B."""
    return PraxisClient(base_url=ogx_url, user_id="user-b", tenant_id="tenant-b")


@pytest.fixture
def tenant_a_user_2_client(ogx_url):
    """HTTP client for User A2 in Tenant A (same tenant as User A, different user)."""
    return PraxisClient(base_url=ogx_url, user_id="user-a2", tenant_id="tenant-a")


@pytest.fixture
def unauthenticated_client(ogx_url):
    """HTTP client without identity headers."""
    return PraxisClient(base_url=ogx_url)
