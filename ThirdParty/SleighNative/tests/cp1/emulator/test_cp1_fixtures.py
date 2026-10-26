import unittest
try:
    from cp1_fixtures import initialize,expected_state,compare_states
except ImportError:
    initialize=expected_state=compare_states=None
class FixtureTests(unittest.TestCase):
    def case(self):
        self.assertIsNotNone(initialize,'fixture initializer/comparator not implemented')
        return {'instruction':'MOVA_ZA_P_RZ_H','encoding':'0xc0400000','inputs':{'SM':1,'ZA':1,'VL_bits':128,'W12':0,'Z0':{'fill_element':'0x11'},'ZA_tile':{'tile':0,'esize':16,'fill_element':'0x77'},'P0_active_elements':[0]},'expected':{'ZA_slice_patch':{'tile':0,'esize':16,'orientation':'H','slice':0,'elements':[0],'fill_element':'0x11'}}}
    def test_input_tile_predicate_and_z(self):
        v=initialize(self.case());self.assertEqual(v.get('Z0')&0xffffffff,0x00110011)
        self.assertEqual(v.get('P0'),1);self.assertEqual(v.read_za_cell(0,16,0,1),0x77)
    def test_expected_patch_does_not_touch_unnamed_cells(self):
        c=self.case();v=initialize(c);e=expected_state(c,v)
        self.assertEqual(e.read_za_cell(0,16,0,0),0x11);self.assertEqual(e.read_za_cell(0,16,0,1),0x77)
        self.assertEqual(v.read_za_cell(0,16,0,0),0x77)
    def test_preservation_detects_non_destination_write(self):
        c=self.case();v=initialize(c);e=expected_state(c,v);v.write_za_cell(0,16,0,0,0x11)
        self.assertEqual(compare_states(c,v,e),{})
        v.set('X29',1);self.assertIn('X29',compare_states(c,v,e))
    def test_missing_initializer_field_is_not_silently_ignored(self):
        c=self.case();c['inputs']['Z99']={'fill_byte':'0x11'}
        with self.assertRaises((ValueError,KeyError)):initialize(c)
if __name__=='__main__':unittest.main()
