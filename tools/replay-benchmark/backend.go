// Local benchmark entry point using the real QuickPizza services, bound only to loopback.
package main

import (
	"log"
	"net/http"
	"os"

	"github.com/grafana/quickpizza/pkg/database"
	qp "github.com/grafana/quickpizza/pkg/http"
)

func main() {
	if len(os.Args) != 2 {
		log.Fatal("pass a test-owned database filename")
	}
	catalog, err := database.NewCatalog("file:" + os.Args[1])
	if err != nil {
		log.Fatal(err)
	}
	copyDB, err := database.NewCopy("file:" + os.Args[1])
	if err != nil {
		log.Fatal(err)
	}
	server := qp.NewServer(false, &qp.OTelInstaller{})
	server.AddLivenessProbes()
	server.AddCatalogHandler(catalog)
	server.AddCopyHandler(copyDB)
	server.AddRecommendations(qp.NewCatalogClient("http://127.0.0.1:18003"), qp.NewCopyClient("http://127.0.0.1:18003"))
	log.Fatal(http.ListenAndServe("127.0.0.1:18003", server))
}
