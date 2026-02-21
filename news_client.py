# news_client.py
"""
News API client for fetching articles (NewsAPI.org).
"""

import requests

BASE_URL = "https://newsapi.org/v2/everything"


class NewsClient:
    def __init__(self, api_key: str):
        self.api_key = api_key

    def fetch(self, query: str, from_date: str = None, to_date: str = None, page_size: int = 100):
        """Fetch articles from News API. Returns list of article dicts."""
        params = {
            "apiKey": self.api_key,
            "q": query,
            "language": "en",
            "sortBy": "relevancy",
            "pageSize": min(page_size, 100),
        }
        if from_date:
            params["from"] = from_date
        if to_date:
            params["to"] = to_date

        try:
            resp = requests.get(BASE_URL, params=params, timeout=15)
            resp.raise_for_status()
            data = resp.json()
            return data.get("articles") or []
        except requests.RequestException as e:
            raise RuntimeError(f"News API error: {e}") from e
