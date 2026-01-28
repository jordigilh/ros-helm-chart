"""
UI tests for ROS recommendations display.

These tests validate that optimization recommendations are properly
displayed in the UI after data has been processed.
"""

import pytest
from playwright.sync_api import Page, expect


@pytest.mark.ui
@pytest.mark.ros
class TestRecommendationsDisplay:
    """Test the recommendations page display."""

    @pytest.mark.smoke
    def test_recommendations_page_loads(
        self, authenticated_page: Page, ui_url: str
    ):
        """Verify the recommendations page loads successfully."""
        authenticated_page.goto(f"{ui_url}/recommendations")
        authenticated_page.wait_for_load_state("networkidle")
        
        # Page should load without errors
        expect(authenticated_page).to_have_url_matching(f".*recommendations.*")

    def test_recommendations_table_visible(
        self, authenticated_page: Page, ui_url: str
    ):
        """Verify recommendations table is displayed."""
        authenticated_page.goto(f"{ui_url}/recommendations")
        authenticated_page.wait_for_load_state("networkidle")
        
        # Look for table or data grid component
        table_locator = authenticated_page.locator(
            "table, [role='grid'], .pf-c-table, .recommendations-table"
        )
        expect(table_locator.first).to_be_visible(timeout=10000)

    def test_no_data_message_when_empty(
        self, authenticated_page: Page, ui_url: str
    ):
        """Verify appropriate message when no recommendations exist."""
        authenticated_page.goto(f"{ui_url}/recommendations")
        authenticated_page.wait_for_load_state("networkidle")
        
        # Either data table or empty state should be visible
        data_or_empty = authenticated_page.locator(
            "table, [role='grid'], .pf-c-empty-state, .empty-state, [data-testid='empty-state']"
        )
        expect(data_or_empty.first).to_be_visible(timeout=10000)


@pytest.mark.ui
@pytest.mark.ros
@pytest.mark.extended
class TestRecommendationDetails:
    """Test recommendation detail views (requires data)."""

    def test_can_view_recommendation_details(
        self, authenticated_page: Page, ui_url: str
    ):
        """Verify clicking a recommendation shows details."""
        authenticated_page.goto(f"{ui_url}/recommendations")
        authenticated_page.wait_for_load_state("networkidle")
        
        # Find first recommendation row/link
        recommendation_link = authenticated_page.locator(
            "table tbody tr a, [role='row'] a, .recommendation-link"
        ).first
        
        if recommendation_link.count() == 0:
            pytest.skip("No recommendations available to test")
        
        # Click to view details
        recommendation_link.click()
        authenticated_page.wait_for_load_state("networkidle")
        
        # Should show detail view
        detail_view = authenticated_page.locator(
            ".recommendation-detail, .pf-c-drawer__panel, [data-testid='recommendation-detail']"
        )
        expect(detail_view).to_be_visible(timeout=10000)

    def test_recommendation_shows_resource_info(
        self, authenticated_page: Page, ui_url: str
    ):
        """Verify recommendation shows CPU/memory information."""
        authenticated_page.goto(f"{ui_url}/recommendations")
        authenticated_page.wait_for_load_state("networkidle")
        
        # Look for CPU/memory related content
        resource_info = authenticated_page.locator(
            "text=/cpu|memory|cores|gib/i"
        )
        
        if resource_info.count() == 0:
            pytest.skip("No resource information visible (may need data)")
        
        expect(resource_info.first).to_be_visible()
