//
//  MetalRenderer.swift
//  RGB2LumaChroma
//
//  Created by Mark Lim Pak Mun on 03/05/2024.
//  Copyright © 2024 Incremental Innovations. All rights reserved.
//

import AppKit
import MetalKit

class MetalRenderer: NSObject, MTKViewDelegate
{
    var metalView: MTKView!
    var metalDevice: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var renderPipelineState: MTLRenderPipelineState!
    var computePipelineState: MTLComputePipelineState!

    var rgbTexture: MTLTexture!             // the original texture.
    var lumaTexture: MTLTexture!            // luminance texture
    var chromaBlueTexture: MTLTexture!      // chrominance blue difference
    var chromaRedTexture: MTLTexture!       // chrominance red difference
    var threadsPerThreadgroup: MTLSize!
    var threadgroupsPerGrid: MTLSize!

    init?(view: MTKView, device: MTLDevice)
    {
        super.init()
        self.metalView = view
        self.metalDevice = device
        self.commandQueue = metalDevice.makeCommandQueue()
        buildResources()
        buildPipelineStates()
    }

    func createMetalTextureFrom(image: NSImage) -> MTLTexture?
    {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        let textureDescr = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                    width: width, height: height,
                                                                    mipmapped: false)
        textureDescr.usage = [.shaderRead]
        guard let cgImage = image.cgImage(forProposedRect: nil,
                                          context: nil,
                                          hints: nil)
        else {
            return nil
        }

        let texLoader = MTKTextureLoader(device: self.metalDevice)
        var texture: MTLTexture?
        // Load as Linear RGB pixel data
        let textureLoaderOptions: [MTKTextureLoader.Option : Any] = [
            .origin : MTKTextureLoader.Origin.topLeft,
            .SRGB : false
        ]
        do {
            texture = try texLoader.newTexture(cgImage: cgImage,
                                               options: textureLoaderOptions)
        }
        catch let error {
            print("error:",error)
            return nil
        }
        return texture
    }

    func buildResources()
    {
        guard let rgbImage = NSImage(named: NSImage.Name("RedFlower.png"))   // Flowers_2.jpg
        else {
            return
        }
        rgbTexture = createMetalTextureFrom(image: rgbImage)

        // Create 3 instances of MTLTexture to capture the outputs of the kernel function.
        let textureDescr = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                    width: rgbTexture.width, height: rgbTexture.height,
                                                                    mipmapped: false)
        textureDescr.storageMode = .managed
        textureDescr.usage = [.shaderRead, .shaderWrite]
        lumaTexture = metalDevice.makeTexture(descriptor: textureDescr)
        lumaTexture.label = "Luminance"

        // The width and height of the chrominance textures are half those of the luminance texture.
        // The area covered by the pixels of the former textures is 1/4 of the latter.
        //textureDescr.pixelFormat = .bgra8Unorm
        textureDescr.width = rgbTexture.width/2
        textureDescr.height = rgbTexture.height/2
        chromaBlueTexture = metalDevice.makeTexture(descriptor: textureDescr)
        chromaBlueTexture.label = "Chrominance Blue"
        chromaRedTexture = metalDevice.makeTexture(descriptor: textureDescr)
        chromaRedTexture.label = "Chrominance Red"
    }

    /*
     Create a kernel function and a rendering pipeline
     */
    func buildPipelineStates()
    {
        // Load all the shader files with a metal file extension in the project
        guard let library = metalDevice.makeDefaultLibrary()
        else {
            fatalError("Could not load default library from main bundle")
        }

        // Use a compute shader function to convert yuv colours to rgb colours.
        let kernelFunction = library.makeFunction(name: "rgb2ycbcrColorConversion")
        do {
            computePipelineState = try metalDevice.makeComputePipelineState(function: kernelFunction!)
        }
        catch {
            fatalError("Unable to create compute pipeline state")
        }

        // To speed up the colour conversion of a video frame, utilise all available threads.
        let w = computePipelineState.threadExecutionWidth
        let h = computePipelineState.maxTotalThreadsPerThreadgroup / w
        threadsPerThreadgroup = MTLSizeMake(w, h, 1)
        threadgroupsPerGrid = MTLSizeMake((rgbTexture.width+threadsPerThreadgroup.width-1) / threadsPerThreadgroup.width,
                                          (rgbTexture.height+threadsPerThreadgroup.height-1) / threadsPerThreadgroup.height,
                                          1)

        ////// Create the render pipeline state for the drawable render pass.
        // Set up a descriptor for creating a pipeline state object
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Render Quad Pipeline"
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "screen_vert")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "screen_frag")

        pipelineDescriptor.sampleCount = metalView.sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        // The attributes of the vertices are generated on the fly.
        pipelineDescriptor.vertexDescriptor = nil

        do {
            renderPipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        catch {
            fatalError("Could not create render pipeline state object: \(error)")
        }
    }

    ///// Implementation of MTKViewDelegate methods.
    func draw(in view: MTKView)
    {
        guard
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable
        else {
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }
        commandBuffer.label = "Render Drawable"

        guard let computeCommandEncoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }
        computeCommandEncoder.label = "Compute Encoder"

        computeCommandEncoder.setComputePipelineState(computePipelineState)
        computeCommandEncoder.setTexture(rgbTexture, index: 0)              //  input texture
        computeCommandEncoder.setTexture(lumaTexture, index: 1)             // output texture
        computeCommandEncoder.setTexture(chromaBlueTexture, index: 2)       // output texture
        computeCommandEncoder.setTexture(chromaRedTexture, index: 3)        // output texture
        computeCommandEncoder.dispatchThreadgroups(threadgroupsPerGrid,
                                                    threadsPerThreadgroup: threadsPerThreadgroup)
        computeCommandEncoder.endEncoding()

        // Render both the luminance and chrominance textures side by side.
        // Metal's 2D coord system has the origin at the top left.
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }
        renderEncoder.label = "Render Encoder"
        /*
         The luma texture's width and height is doubled those of the chroma texture.
         To look good, we set the view's width to be double that of the width of the chroma texture
         and the view's height to be the same as the chroma texture using XCode's IB module.
         Note: the display appears to show both textures are of the same size. But the actual size
         of the chrominance texture is 1/4 that of the luminance texture.
         */
        let   textures = [rgbTexture, lumaTexture, chromaBlueTexture, chromaRedTexture]
        let  viewWidth = Double(view.drawableSize.width)
        let viewHeight = Double(view.drawableSize.height)

        // All 4 quadrants have the same width and height.
        // Only their origins differ.
        //              top-left    top-right       bottom-left     bottom-right
        let originsX = [    0.0,     viewWidth/2,      0.0,         viewWidth/2]
        let originsY = [    0.0,         0.0,       viewHeight/2,   viewHeight/2]
        let   widths = [viewWidth/2,  viewWidth/2,  viewWidth/2,    viewWidth/2]
        let  heights = [viewHeight/2, viewHeight/2, viewHeight/2,   viewHeight/2]
        renderEncoder.setRenderPipelineState(renderPipelineState)

        // Since all 4 quadrants have the same width and height, we can just
        // set the width and height of the 4 view ports to their common values.
        var viewPort = MTLViewport()
        viewPort.znear = -1.0
        viewPort.znear =  1.0
        for i in 0 ..< textures.count {
            viewPort.originX = originsX[i]
            viewPort.originY = originsY[i]
            viewPort.width = widths[i]          // viewWidth/2
            viewPort.height = heights[i]        // viewHeight/2
            renderEncoder.setViewport(viewPort)
            renderEncoder.setFragmentTexture(textures[i],
                                             index: 0)
            // Output the triangle which is clipped to a quad.
            renderEncoder.drawPrimitives(type: .triangle,
                                         vertexStart: 0,
                                         vertexCount: 3)
        }
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
    {
        // Does nothing
    }
}
