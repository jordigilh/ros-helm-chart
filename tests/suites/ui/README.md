# UI Tests (Playwright)

Browser-based UI tests using [Playwright](https://playwright.dev/) for end-to-end validation of the Cost Management UI.

## Overview

These tests validate:
- **Login Flow**: OAuth/OIDC authentication via Keycloak
- **Recommendations Display**: ROS optimization recommendations in the UI
- **Navigation**: Protected routes and session persistence

## Prerequisites

### Install Playwright Browsers

After installing dependencies, install the Playwright browsers:

```bash
# Install browsers (run once)
playwright install chromium

# Or install all browsers
playwright install
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PLAYWRIGHT_BROWSER` | `chromium` | Browser to use (`chromium`, `firefox`, `webkit`) |
| `PLAYWRIGHT_HEADLESS` | `true` | Run in headless mode |
| `PLAYWRIGHT_SLOW_MO` | `0` | Slow down actions by N milliseconds (for debugging) |
| `TEST_UI_USERNAME` | `test` | Keycloak test user username |
| `TEST_UI_PASSWORD` | `test` | Keycloak test user password |

## Running Tests

```bash
# Run all UI tests
pytest -m ui

# Run UI smoke tests only
pytest -m "ui and smoke"

# Run with visible browser (for debugging)
PLAYWRIGHT_HEADLESS=false pytest -m ui

# Run with slow motion (see what's happening)
PLAYWRIGHT_HEADLESS=false PLAYWRIGHT_SLOW_MO=500 pytest -m ui

# Run specific test file
pytest suites/ui/test_login_flow.py

# Run with different browser
PLAYWRIGHT_BROWSER=firefox pytest -m ui
```

## Test Structure

```
suites/ui/
├── __init__.py
├── conftest.py           # Playwright fixtures
├── README.md             # This file
├── test_login_flow.py    # Keycloak OAuth login tests
└── test_recommendations.py # ROS recommendations display tests
```

## Fixtures

### Browser Fixtures

| Fixture | Scope | Description |
|---------|-------|-------------|
| `playwright_instance` | session | Playwright instance |
| `browser` | session | Browser instance (Chromium by default) |
| `browser_context` | function | Fresh context per test (isolated cookies/storage) |
| `page` | function | Fresh page per test |

### Authentication Fixtures

| Fixture | Scope | Description |
|---------|-------|-------------|
| `authenticated_context` | function | Browser context with logged-in session |
| `authenticated_page` | function | Page with logged-in session |

### URL Fixtures

| Fixture | Scope | Description |
|---------|-------|-------------|
| `ui_url` | session | Cost Management UI URL |
| `keycloak_login_url` | session | Keycloak login page URL |

## Debugging

### Screenshots on Failure

Screenshots are automatically captured when tests fail and saved to:
```
tests/reports/screenshots/<test_name>.png
```

### Running with Visible Browser

```bash
PLAYWRIGHT_HEADLESS=false pytest -m ui -k test_login
```

### Using Playwright Inspector

```bash
PWDEBUG=1 pytest -m ui -k test_login
```

### Generating Tests with Codegen

```bash
# Record actions and generate test code
playwright codegen https://your-ui-url.example.com
```

## Writing New Tests

### Basic Test Structure

```python
import pytest
from playwright.sync_api import Page, expect

@pytest.mark.ui
class TestMyFeature:
    def test_something(self, page: Page, ui_url: str):
        page.goto(ui_url)
        expect(page.locator("h1")).to_have_text("Expected Title")
```

### Using Authenticated Session

```python
@pytest.mark.ui
class TestProtectedFeature:
    def test_requires_auth(self, authenticated_page: Page, ui_url: str):
        # Already logged in
        authenticated_page.goto(f"{ui_url}/protected-route")
        expect(authenticated_page).not_to_have_url_matching(".*keycloak.*")
```

### Best Practices

1. **Use `expect()` assertions** - They auto-wait and provide better error messages
2. **Use semantic locators** - Prefer `role`, `text`, `label` over CSS selectors
3. **Wait for network idle** - Use `page.wait_for_load_state("networkidle")` after navigation
4. **Handle dynamic content** - Use `expect().to_be_visible(timeout=N)` for async content
5. **Skip when no data** - Use `pytest.skip()` when tests require data that may not exist

## CI Integration

UI tests are excluded from the default CI run. To include them:

```bash
# Run all tests including UI
pytest -m "not extended or ui"

# Run only UI tests in CI
pytest -m ui --browser chromium
```

For CI, ensure:
1. Playwright browsers are installed in the CI image
2. `PLAYWRIGHT_HEADLESS=true` is set
3. Screenshots directory is preserved as artifacts
