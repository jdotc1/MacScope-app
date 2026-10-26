#!/usr/bin/env python3
import unittest
try:
    from cp1_vm import SMEVM,parse
except ImportError:
    SMEVM=None
class VMTests(unittest.TestCase):
    def vm(self,**kw):
        self.assertIsNotNone(SMEVM,'SME state/VM extension is not implemented')
        return SMEVM(**kw)
    def test_z_segments_alias_existing_q(self):
        for be in (False,True):
            v=self.vm(be=be);raw=(1<<2047)|(0x1234<<256)|0x89abcdef;v.set('Z2',raw)
            self.assertEqual(v.get('Z2'),raw);self.assertEqual(v.get('q2'),0x89abcdef)
            v.set('d2',7);self.assertEqual(v.get('Z2')&((1<<64)-1),7)
            self.assertEqual(v.get('Z2')>>256,raw>>256)
    def test_pn_is_p_alias_in_both_segments(self):
        v=self.vm();v.set('PN15',(1<<255)|0x8001);self.assertEqual(v.get('P15'),(1<<255)|0x8001)
        v.set('P15',0x81);self.assertEqual(v.get('PN15'),0x81)
    def test_za_tile_views_alias(self):
        v=self.vm();v.write_za_cell(1,16,2,3,0xabcd)
        self.assertEqual(v.read_za_cell(0,8,5,6),0xcd)
        self.assertEqual(v.read_za_cell(0,8,5,7),0xab)
    def test_svcr_single_state_source(self):
        v=self.vm();v.set('SVCR',3);self.assertEqual(v.get('SM'),1);self.assertEqual(v.get('ZA'),1)
        v.set('SM',0);self.assertEqual(v.get('SVCR'),2);self.assertEqual(v.get('ZA'),1)
    def test_register_indirect_load_store(self):
        v=self.vm(spaces={0:'const',1:'ram',2:'register',3:'unique'})
        v.run(parse('(unique,0x10,8) = COPY (const,0x1234,8)\nSTORE (const,0x2,8), (const,0x20000,4), (unique,0x10,8)\n(unique,0x20,8) = LOAD (const,0x2,8), (const,0x20000,4)'))
        self.assertEqual(v.read(('unique',0x20,8)),0x1234)
    def test_unknown_calother_never_becomes_noop(self):
        v=self.vm()
        with self.assertRaises(NotImplementedError):v.run(parse('(register,0x7008,8) = CALLOTHER (const,0xffff,4), (const,0x1,8)'))
    def test_oversized_register_access_rejected(self):
        v=self.vm()
        with self.assertRaises(ValueError):v.read(('register',2**64-1,8))
    def test_arithmetic_signed_division_truncates_towards_zero(self):
        v=self.vm();v.write(('unique',0x10,8),-7)
        v.run(parse('(unique,0x20,8) = INT_SDIV (unique,0x10,8), (const,0x3,8)'))
        self.assertEqual(v.read(('unique',0x20,8)),(1<<64)-2)
if __name__=='__main__':unittest.main()
