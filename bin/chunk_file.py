from fastcdc import fastcdc as fastcdc_rust
import blake3

def fastcdc(path, min_size=4096, avg_size=16384, max_size=65536):
    """Yield (offset, size, blake3_hex) for each chunk.

    Uses Rust fastcdc implementation for performance.
    """
    with open(path, 'rb') as f:
        data = f.read()

    for chunk in fastcdc_rust(data, min_size=min_size, avg_size=avg_size, max_size=max_size):
        offset = chunk.offset
        length = chunk.length
        chunk_data = data[offset:offset+length]
        chunk_hash = blake3.blake3(chunk_data).hexdigest()
        yield (offset, length, chunk_hash)
