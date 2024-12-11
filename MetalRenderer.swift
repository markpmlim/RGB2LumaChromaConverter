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
    var metalDevice: MTLDevice
    var commandQueue: MTLCommandQueue!
    var renderPipelineState: MTLRenderPipelineState!
    var computePipelineState: MTLComputePipelineState!

    var lumaTexture: MTLTexture!
    var chromaTexture: MTLTexture!
    var rgbTexture: MTLTexture!             // the original texture.
    var threadsPerThreadgroup: MTLSize!
    var threadgroupsPerGrid: MTLSize!

    init?(view: MTKView, device: MTLDevice)
    {
        self.metalView = view
        self.metalDevice = device
        self.commandQueue = metalDevice.makeCommandQueue()
        super.init()
        buildResources()
        buildPipelineStates()
    }

    func createMetalTextureFrom(image: NSImage) -> MTLTexture?
    {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        let textureDescr = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
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
        guard let rgbImage = NSImage(named: NSImage.Name("Flowers_2.jpg"))
        else {
            return
        }
        rgbTexture = createMetalTextureFrom(image: rgbImage)

        // Create two instances of MTLTexture to capture the output of the kernel function.
        // The pixel format of the luma texture is .r8Unorm and the chroma texture is .rg8Unorm
        // Note: both textures can be saved as-is. Not need to save as RGB/RGBA image file.
        let textureDescr = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                                    width: rgbTexture.width, height: rgbTexture.height,
                                                                    mipmapped: false)
        textureDescr.storageMode = .managed
        textureDescr.usage = [.shaderRead, .shaderWrite]
        lumaTexture = metalDevice.makeTexture(descriptor: textureDescr)
        lumaTexture.label = "Luminance"

        // The width and height of the chrominance texture are half those of the luminance texture.
        // The area covered by the pixels of the former is 1/4 of the latter.
        textureDescr.pixelFormat = .rg8Unorm
        textureDescr.width = rgbTexture.width/2
        textureDescr.height = rgbTexture.height/2
        chromaTexture = metalDevice.makeTexture(descriptor: textureDescr)
        chromaTexture.label = "Chrominance"
    }

    /*
     We have a kernel function and a rendering pipeline
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
        computeCommandEncoder.setTexture(rgbTexture, index: 0)              // output texture
        computeCommandEncoder.setTexture(lumaTexture, index: 1)             //  input texture
        computeCommandEncoder.setTexture(chromaTexture, index: 2)           //  input texture
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
 
        // Draw the luminance texture on the left side of the view
        var viewPort = MTLViewport(originX: 0.0, originY: 0.0,
                                   width: Double(view.drawableSize.width/2), height: Double(view.drawableSize.height),
                                   znear: -1.0, zfar: 1.0)
        renderEncoder.setViewport(viewPort)
        renderEncoder.setRenderPipelineState(renderPipelineState)

        renderEncoder.setFragmentTexture(lumaTexture,
                                         index : 0)

        // The attributes of the vertices are generated on the fly.
        renderEncoder.drawPrimitives(type: .triangle,
                                     vertexStart: 0,
                                     vertexCount: 3)

        // Draw the chrominance texture on the right side of the view.
        // You might want to set the rendered chroma texture as 1/4 of the luma texture.
        // Divide the drawableSize's width to 1/4 and its height by 2
        viewPort = MTLViewport(originX: Double(view.drawableSize.width/2), originY: 0.0,
                               width: Double(view.drawableSize.width/2), height: Double(view.drawableSize.height),
                               znear: -1.0, zfar: 1.0)
        renderEncoder.setViewport(viewPort)

        renderEncoder.setFragmentTexture(chromaTexture,
                                          index : 0)

        renderEncoder.drawPrimitives(type: .triangle,
                                      vertexStart: 0,
                                      vertexCount: 3)

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
