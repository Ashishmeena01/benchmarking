
package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
)

const (
	PORT            = ":8080"
	MAX_REQUEST_SIZE = 16 * 1024
)

func handleConnection(conn net.Conn) {
	defer conn.Close()

	reader := bufio.NewReader(conn)
	var request strings.Builder

	// Read HTTP headers until the end marker.
	for {
		line, err := reader.ReadString('\n')

		if err != nil {
			if err != io.EOF {
				log.Println("Read error:", err)
			}
			return
		}

		request.WriteString(line)

		if request.Len() > MAX_REQUEST_SIZE {
			return
		}

		if strings.HasSuffix(request.String(), "\r\n\r\n") {
			break
		}
	}

	// Build HTTP response.
	body := "Hello World\n"

	response := fmt.Sprintf(
		"HTTP/1.1 200 OK\r\n"+
			"Content-Type: text/plain\r\n"+
			"Content-Length: %d\r\n"+
			"Connection: close\r\n"+
			"\r\n"+
			"%s",
		len(body),
		body,
	)

	// Write the complete response.
	if _, err := io.WriteString(conn, response); err != nil {
		log.Println("Write error:", err)
	}
}

func main() {
	listener, err := net.Listen("tcp", PORT)

	if err != nil {
		log.Fatal("Could not start server:", err)
	}

	defer listener.Close()

	log.Println("Go HTTP server listening on http://localhost:8080")

	for {
		conn, err := listener.Accept()

		if err != nil {
			log.Println("Accept error:", err)
			continue
		}

		// One goroutine handles each connection.
		go handleConnection(conn)
	}
}
