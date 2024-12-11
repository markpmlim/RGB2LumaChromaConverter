//
//  ViewController.swift
//  RGB2LumaChroma
//
//  Created by Mark Lim Pak Mun on 03/05/2024.
//  Copyright © 2024 Incremental Innovations. All rights reserved.
//

import Cocoa
import MetalKit

class ViewController: NSViewController
{
    var metalView: MTKView {
        return self.view as! MTKView
    }

    var metalRenderer: MetalRenderer!

    var ciContext: CIContext!
    var colorSpace: CGColorSpace!

    override func viewDidLoad()
    {
        super.viewDidLoad()

        guard let defaultDevice = MTLCreateSystemDefaultDevice()
        else {
            fatalError("No Metal-capable GPU")
        }

        metalView.colorPixelFormat = .bgra8Unorm
        metalView.device = defaultDevice
        metalRenderer = MetalRenderer(view: metalView, device: defaultDevice)
        metalView.delegate = metalRenderer

        metalRenderer.mtkView(metalView,
                              drawableSizeWillChange: metalView.drawableSize)

        colorSpace = metalView.colorspace
        if colorSpace == nil {
            colorSpace = CGColorSpaceCreateDeviceRGB()
        }
        let options = [CIContextOption.outputColorSpace : colorSpace!]
        ciContext = CIContext(mtlDevice: metalView.device!,
                              options: options)
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }

    override func viewDidAppear()
    {
        metalView.window!.makeFirstResponder(self)
    }

    /*
     Save the files named "luma.jpg", "chromaBlue.jpg" and "chromaRed.jpg" to
     a folder specified by the user. The 3 file names are hard-coded.
     */
    func save(mtlTextures: [MTLTexture], to folderURL: URL) throws
    {
        let fmgr = FileManager.`default`
        var isDir = ObjCBool(false)
        // Check the folder at url exist.
        if !fmgr.fileExists(atPath: folderURL.path,
                            isDirectory: &isDir) {
            // The file/directory does not exist; just, create the destination folder.
            try fmgr.createDirectory(at: folderURL,
                                     withIntermediateDirectories: true,
                                     attributes: nil)
        }
        else {
            // file or folder exists
            // Make sure it is not an ordinary data file
            if !isDir.boolValue {
                print("A file exists at the location:", folderURL)
                print("Cannot save the three textures")
                return
            }
        }

        // The files "luma.jpg", "chromaBlue.jpg" and "chromaRed.jpg will be written out
        // to the destination folder.
        let lumaURL = folderURL.appendingPathComponent("luma").appendingPathExtension("jpg")
        let chromaBlueURL = folderURL.appendingPathComponent("chromaBlue").appendingPathExtension("jpg")
        let chromaRedURL = folderURL.appendingPathComponent("chromaRed").appendingPathExtension("jpg")
        let fileURLS = [lumaURL, chromaBlueURL, chromaRedURL]

        for i in 0..<fileURLS.count {
            var ciImage = CIImage(mtlTexture: mtlTextures[i],
                                  options: [CIImageOption.colorSpace: colorSpace!])!
            var transform = CGAffineTransform(translationX: 0.0,
                                              y: ciImage.extent.height)
            // We need to flip the image vertically.
            transform = transform.scaledBy(x: 1.0, y: -1.0)
            ciImage = ciImage.transformed(by: transform)
            do {
                try ciContext.writeJPEGRepresentation(of: ciImage,
                                                      to: fileURLS[i],
                                                      colorSpace: colorSpace!,
                                                      options: [:])
            }
            catch let err {
                print("Error: \(err). Can't write file: ", fileURLS[i].lastPathComponent)
                throw err
            }
        }
    }

    // Press 's' or 'S' to save the textures.
    override func keyDown(with event: NSEvent)
    {
        if event.keyCode == 0x1 {
            guard
                let lumaTexture = metalRenderer.lumaTexture,
                let chromaBlueTexture =  metalRenderer.chromaBlueTexture,
                let chromaRedTexture =  metalRenderer.chromaRedTexture
            else {
                super.keyDown(with: event)
                return
            }
            let sp = NSSavePanel()
            sp.canCreateDirectories = true
            sp.nameFieldLabel = "Save to Folder"    // We are saving to a folder
            sp.nameFieldStringValue = "textures"    // Name of the folder
            let button = sp.runModal()

            if (button == NSApplication.ModalResponse.OK) {
                var folderURL = sp.url!
                // Strip away any file extension from the folder name.
                let ext = folderURL.pathExtension
                if !ext.isEmpty {
                    folderURL.deletePathExtension()
                }
                do {
                    try self.save(mtlTextures: [lumaTexture, chromaBlueTexture, chromaRedTexture],
                                  to: folderURL)
                }
                catch let err {
                    Swift.print(err)
                }
            }
        }
        else {
            super.keyDown(with: event)
        }
    }

}

