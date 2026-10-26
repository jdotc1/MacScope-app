#!/usr/bin/env python3
"""Regression for actual BE SLEIGH overlapping unique-temporary offsets."""
import unittest
from rx17_semantics import VM
class ByteOrderTests(unittest.TestCase):
    def test_overlapping_unique_temporaries_in_both_languages(self):
        for be,low_offset,high_offset in ((False,0x178400,0x178404),(True,0x178404,0x178400)):
            with self.subTest(big_endian=be):
                vm=VM(be)
                vm.write(('unique',0x178400,8),0x1122334455667788)
                self.assertEqual(vm.read(('unique',low_offset,4)),0x55667788)
                self.assertEqual(vm.read(('unique',high_offset,4)),0x11223344)
                vm.write(('unique',low_offset,4),0xaabbccdd)
                self.assertEqual(vm.read(('unique',0x178400,8)),0x11223344aabbccdd)
                vm.run([('COPY',('unique',0x200000,4),[('unique',low_offset,4)])])
                self.assertEqual(vm.read(('unique',0x200000,4)),0xaabbccdd)
if __name__=='__main__': unittest.main()
