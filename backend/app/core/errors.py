"""HTTP error carrying a stable machine-readable `code` next to a plain-string `detail`.

`detail` must stay a string: the shipped iOS client decodes it as String?. The
code travels as an extra top-level field (see the handler in app/main.py)."""
from fastapi import HTTPException


class CodedHTTPException(HTTPException):
    def __init__(self, status_code: int, detail: str, code: str):
        super().__init__(status_code, detail=detail)
        self.code = code
