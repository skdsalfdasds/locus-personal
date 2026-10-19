import asyncio
import logging

from backend.server import Backend

if __name__ == '__main__':
    logging.basicConfig(level=logging.ERROR)
    asyncio.run(Backend().serve())
