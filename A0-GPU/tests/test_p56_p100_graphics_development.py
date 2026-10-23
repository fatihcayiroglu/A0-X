"""One explicit software acceptance test per P56-P80 capability.

These are NOT RTL tests. Each phase is accepted only as a prototype API.
"""
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_nextgen_graphics_p56_p80 import *


def tricolor(z=0.5,rgba=(1.,0.,0.,1.),uv=(0.,0.)):
    return (Vertex(1,1,z,rgba,uv),Vertex(6,1,z,rgba,uv),Vertex(1,6,z,rgba,uv))

class PrototypeGraphics(unittest.TestCase):
    def test_p56_surface_bounds(self):
        with self.assertRaises(ValueError): Framebuffer(256,257)
        self.assertEqual((Framebuffer(4,4).width,Framebuffer(4,4).height),(4,4))
        with self.assertRaises(ValueError): Framebuffer(0,3)

    def test_p57_clear(self):
        fb=Framebuffer(8,8);fb.clear((.2,.5,0.,1.))
        self.assertEqual(fb.pixel(3,4),(51,128,0,255))
        self.assertEqual(fb.depths[0],1.0)

    def test_p58_viewport(self):
        fb=Framebuffer(16,16)
        fb.draw(tricolor(),GraphicsState(viewport=(5,5)))
        self.assertEqual(fb.pixel(2,2),(0,0,0,255))
        self.assertEqual(fb.pixel(7,7),(255,0,0,255))

    def test_p59_scissor(self):
        fb=Framebuffer(8,8)
        fb.draw(tricolor(),GraphicsState(scissor=Rect(2,2,1,1)))
        self.assertEqual(sum(1 for x in fb.colors if x[0]>.5),1)
        with self.assertRaises(ValueError): Rect(1,1,-3,1)

    def test_p60_viewport_clip(self):
        fb=Framebuffer(4,4)
        verts=(Vertex(-1000,-1000),Vertex(2000,-1000),Vertex(-1000,2000))
        fb.draw(verts)
        self.assertTrue(0 < sum(1 for x in fb.colors if x[0]>.5)<=16)

    def test_p61_vertex_validation(self):
        with self.assertRaises(ValueError):Vertex(1.3,2)
        with self.assertRaises(ValueError):Vertex(1,2,float('nan'))
        with self.assertRaises(ValueError):Vertex(1,2,rgba=(1,2,float('nan'),4))

    def test_p62_triangle_primitive(self):
        fb=Framebuffer(8,8)
        self.assertGreater(fb.draw(tricolor()),0)
        with self.assertRaises(ValueError):list(triangle_fragments(tricolor()[:2],8,8))

    def test_p63_cull(self):
        front=Framebuffer(8,8);back=Framebuffer(8,8)
        self.assertEqual(back.draw(tricolor(),GraphicsState(cull='ccw')),0)
        self.assertGreater(front.draw(tricolor(),GraphicsState(cull='cw')),0)

    def test_p64_degenerate(self):
        fb=Framebuffer(8,8)
        tri=(Vertex(1,1),Vertex(3,3),Vertex(5,5))
        self.assertEqual(fb.draw(tri),0)

    def test_p65_top_left_shared_edge(self):
        f=Framebuffer(4,4)
        a=(Vertex(0,0),Vertex(4,0),Vertex(0,4))
        b=(Vertex(4,0),Vertex(4,4),Vertex(0,4))
        pixels_a={(x,y) for x,y,*_ in triangle_fragments(a,4,4)}
        pixels_b={(x,y) for x,y,*_ in triangle_fragments(b,4,4)}
        self.assertFalse(pixels_a & pixels_b)
        self.assertEqual(len(pixels_a | pixels_b),16)

    def test_p66_barycentric(self):
        fragments=list(triangle_fragments(tricolor(z=.25),8,8))
        self.assertTrue(fragments)
        for _,_,depth,rgba,uv in fragments:
            self.assertAlmostEqual(depth,.25)
            self.assertAlmostEqual(rgba[0],1.)

    def test_p67_interpolated_color(self):
        tri=(Vertex(0,0,rgba=(1,0,0,1)),Vertex(8,0,rgba=(0,1,0,1)),Vertex(0,8,rgba=(0,0,1,1)))
        fb=Framebuffer(8,8)
        fb.draw(tri)
        self.assertGreater(fb.pixel(2,2)[1],0)
        self.assertGreater(fb.pixel(2,2)[2],0)

    def test_p68_depth_less(self):
        fb=Framebuffer(8,8)
        fb.draw(tricolor(.4,(1,0,0,1)))
        fb.draw(tricolor(.8,(0,1,0,1)))
        self.assertEqual(fb.pixel(2,2),(255,0,0,255))

    def test_p69_depth_write_disable(self):
        fb=Framebuffer(8,8)
        fb.draw(tricolor(.2,(1,0,0,1)),GraphicsState(depth_write=False))
        self.assertEqual(fb.depths[2*8+2],1.)
        fb.draw(tricolor(.8,(0,1,0,1)))
        self.assertEqual(fb.pixel(2,2),(0,255,0,255))

    def test_p70_source_over(self):
        fb=Framebuffer(8,8)
        fb.draw(tricolor(.2,(1,0,0,.5)),GraphicsState(blending=True))
        self.assertEqual(fb.pixel(2,2)[0],128)
        self.assertEqual(fb.pixel(2,2)[3],255)

    def test_p71_texture_contract(self):
        with self.assertRaises(ValueError):Texture(2,2,((1.,1.,1.,1.),))
        tex=Texture(2,1,((1,0,0,1),(0,0,1,1)))
        self.assertEqual(tex.pixel(1,0),(0.,0.,1.,1.))

    def test_p72_sampler_clamp(self):
        tex=Texture(2,1,((1,0,0,1),(0,0,1,1)))
        self.assertEqual(sample(tex,(-100.,0.)),(1.,0.,0.,1.))
        self.assertEqual(sample(tex,(100.,0.)),(0.,0.,1.,1.))

    def test_p73_sampler_repeat(self):
        tex=Texture(2,1,((1,0,0,1),(0,0,1,1)))
        self.assertEqual(sample(tex,(1.25,0.),mode='repeat'),(1.,0.,0.,1.))
        self.assertEqual(sample(tex,(-.25,0.),mode='repeat'),(0.,0.,1.,1.))

    def test_p74_nearest_sample(self):
        tex=Texture(2,2,((1,0,0,1),(0,1,0,1),(0,0,1,1),(1,1,1,1)))
        self.assertEqual(sample(tex,(.9,.9)),(1.,1.,1.,1.))

    def test_p75_linear_sample(self):
        tex=Texture(2,1,((0,0,0,1),(1,1,1,1)))
        self.assertAlmostEqual(sample(tex,(.5,.5),filtering='linear')[0],.5)

    def test_p76_shader_rejects_bad_code(self):
        with self.assertRaises(ValueError):Shader((('EVIL','r0','color','one'),))
        with self.assertRaises(ValueError):Shader(tuple([('MOV','r0','color','one')]*33))

    def test_p77_shader_mul_add(self):
        s=Shader((('MUL','r0','color','const0'),('ADD','r1','r0','zero')))
        self.assertEqual(s.evaluate((.5,.25,1.,1.),(0,0),const0=(2,2,2,1)),(1.,.5,2.,1.))

    def test_p78_shader_interpolated_input(self):
        fb=Framebuffer(8,8)
        s=Shader((('MOV','r0','color','zero'),))
        fb.draw(tricolor(rgba=(.25,.5,.75,1.)),GraphicsState(shader=s))
        self.assertEqual(fb.pixel(2,2)[:3],(64,128,191))

    def test_p79_shader_uniforms(self):
        fb=Framebuffer(8,8)
        s=Shader((('MUL','r0','color','const0'),))
        fb.draw(tricolor(),GraphicsState(shader=s,uniform=(0,.7,0,1)))
        self.assertEqual(fb.pixel(2,2)[:3],(0,0,0))

    def test_p80_bounded_tex_shader(self):
        texture=Texture(1,1,((0,1,0,1),))
        shader=Shader((('TEX','r0','uv','one'),))
        fb=Framebuffer(8,8)
        fb.draw(tricolor(),GraphicsState(shader=shader,texture=texture))
        self.assertEqual(fb.pixel(2,2),(0,255,0,255))
        with self.assertRaises(ValueError):shader.evaluate((1,1,1,1),(0,0))

if __name__=='__main__':unittest.main()
