package main

import (
	"embed"
	"fmt" // Added for debug prints
	"log"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

//go:embed all:frontend/dist
var assets embed.FS

//go:embed build/appicon.png
var icon []byte

func main() {
	fmt.Println("DEBUG: main.go - Start of main") // Added for debug
	// Create an instance of the app structure
	app := NewApp()

	// Create application with options
	fmt.Println("DEBUG: main.go - Before wails.Run()") // Added for debug
	err := wails.Run(&options.App{
		Title:             "Bridge Controller",
		Width:             800,
		Height:            600,
		DisableResize:     false,
		Fullscreen:        false,
		Frameless:         false,
		StartHidden:       false,
		HideWindowOnClose: false,
		BackgroundColour:  &options.RGBA{R: 27, G: 38, B: 54, A: 1},
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		Windows: &windows.Options{
			WebviewIsTransparent: false,
			WindowIsTranslucent:  false,
			DisableWindowIcon:    false,
		},
		OnStartup:  app.startup,
		OnShutdown: app.shutdown,
		Bind: []interface{}{
			app,
		},
	})
	fmt.Println("DEBUG: main.go - After wails.Run()") // Added for debug

	if err != nil {
		log.Fatal(err)
	}
}
