"""Offline tests for dependency provenance and Android native ABI boundaries."""
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location("xray_bootstrap", Path(__file__).with_name("bootstrap_xray_android.py"))
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


def elf(abi, alignment=16384):
    is64 = abi == "arm64-v8a"
    result = bytearray(160)
    result[:6] = b"\x7fELF" + bytes((2 if is64 else 1, 1))
    struct.pack_into("<H", result, 18, 183 if is64 else 40)
    struct.pack_into("<Q" if is64 else "<I", result, 32 if is64 else 28, 64)
    struct.pack_into("<H", result, 54 if is64 else 42, 56 if is64 else 32)
    struct.pack_into("<H", result, 56 if is64 else 44, 1)
    struct.pack_into("<I", result, 64, 1)
    struct.pack_into("<Q" if is64 else "<I", result, 64 + (48 if is64 else 28), alignment)
    return bytes(result)


class AndroidDependencyTests(unittest.TestCase):
    def test_both_shipping_arm_abis_have_valid_16k_program_headers(self):
        for abi in ("arm64-v8a", "armeabi-v7a"):
            bootstrap.verify_elf(elf(abi), abi)

    def test_four_kib_or_mislabeled_architecture_is_rejected(self):
        for abi in ("arm64-v8a", "armeabi-v7a"):
            with self.assertRaises(ValueError):
                bootstrap.verify_elf(elf(abi, 4096), abi)
        with self.assertRaises(ValueError):
            bootstrap.verify_elf(elf("arm64-v8a"), "armeabi-v7a")

    def test_truncated_or_unbounded_program_headers_are_rejected(self):
        with self.assertRaises(ValueError):
            bootstrap.verify_elf(b"\x7fELF", "arm64-v8a")
        value = bytearray(elf("arm64-v8a"))
        struct.pack_into("<Q", value, 32, 999999)
        with self.assertRaises(ValueError):
            bootstrap.verify_elf(bytes(value), "arm64-v8a")


if __name__ == "__main__":
    unittest.main()
