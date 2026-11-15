
#define WIN32_LEAN_AND_MEAN

#include <winsock2.h>
#include <windows.h>
#include <mswsock.h>
#include <cstring>

#include <iostream>
#include <string>
#include <vector>
#include <thread>
#include <memory>
#include <algorithm>

#pragma comment(lib, "ws2_32.lib")

constexpr int PORT = 8080;
constexpr DWORD BUFFER_SIZE = 4096;
constexpr size_t MAX_REQUEST = 16 * 1024;

enum class OperationType {
    Read,
    Write
};

struct Connection;

struct Operation {
    OVERLAPPED overlapped{};
    WSABUF wsabuf{};
    OperationType type;
    Connection* connection;
    char buffer[BUFFER_SIZE]{};
};

struct Connection {
    SOCKET socket;
    std::string request;
    std::string response;
    size_t sent = 0;
};

HANDLE completionPort = nullptr;

void closeConnection(Connection* connection) {
    if (!connection) return;

    closesocket(connection->socket);
    delete connection;
}

bool postRead(Connection* connection) {
    auto* op = new Operation{};
    op->type = OperationType::Read;
    op->connection = connection;

    op->wsabuf.buf = op->buffer;
    op->wsabuf.len = BUFFER_SIZE;

    DWORD flags = 0;
    DWORD received = 0;

    int result = WSARecv(
        connection->socket,
        &op->wsabuf,
        1,
        &received,
        &flags,
        &op->overlapped,
        nullptr
    );

    if (result == SOCKET_ERROR &&
        WSAGetLastError() != WSA_IO_PENDING) {
        delete op;
        return false;
    }

    return true;
}

bool postWrite(Connection* connection) {
    auto* op = new Operation{};
    op->type = OperationType::Write;
    op->connection = connection;

    size_t remaining =
        connection->response.size() - connection->sent;

    size_t amount = std::min(
        remaining,
        static_cast<size_t>(BUFFER_SIZE)
    );

    memcpy(op->buffer,
           connection->response.data() + connection->sent,
           amount);

    op->wsabuf.buf = op->buffer;
    op->wsabuf.len = static_cast<ULONG>(amount);

    DWORD sent = 0;

    int result = WSASend(
        connection->socket,
        &op->wsabuf,
        1,
        &sent,
        0,
        &op->overlapped,
        nullptr
    );

    if (result == SOCKET_ERROR &&
        WSAGetLastError() != WSA_IO_PENDING) {
        delete op;
        return false;
    }

    return true;
}

void worker() {
    while (true) {
        DWORD bytesTransferred = 0;
        ULONG_PTR completionKey = 0;
        OVERLAPPED* overlapped = nullptr;

        BOOL success = GetQueuedCompletionStatus(
            completionPort,
            &bytesTransferred,
            &completionKey,
            &overlapped,
            INFINITE
        );

        if (!overlapped) {
            continue;
        }

        auto* op = reinterpret_cast<Operation*>(overlapped);
        Connection* connection = op->connection;

        if (!success || bytesTransferred == 0) {
            delete op;
            closeConnection(connection);
            continue;
        }

        if (op->type == OperationType::Read) {
            connection->request.append(
                op->buffer,
                bytesTransferred
            );

            delete op;

            if (connection->request.size() > MAX_REQUEST) {
                closeConnection(connection);
                continue;
            }

            if (connection->request.find("\r\n\r\n") ==
                std::string::npos) {
                if (!postRead(connection)) {
                    closeConnection(connection);
                }
                continue;
            }

            const std::string body = "Hello World\n";

            connection->response =
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/plain\r\n"
                "Content-Length: " +
                std::to_string(body.size()) +
                "\r\n"
                "Connection: close\r\n"
                "\r\n" +
                body;

            connection->sent = 0;

            if (!postWrite(connection)) {
                closeConnection(connection);
            }
        }
        else {
            connection->sent += bytesTransferred;
            delete op;

            if (connection->sent < connection->response.size()) {
                if (!postWrite(connection)) {
                    closeConnection(connection);
                }
            }
            else {
                closeConnection(connection);
            }
        }
    }
}

int main() {
    WSADATA wsaData{};

    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
        std::cerr << "WSAStartup failed\n";
        return 1;
    }

    SOCKET listenSocket = socket(
        AF_INET,
        SOCK_STREAM,
        IPPROTO_TCP
    );

    if (listenSocket == INVALID_SOCKET) {
        std::cerr << "Socket creation failed\n";
        WSACleanup();
        return 1;
    }

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons(PORT);

    if (bind(
        listenSocket,
        reinterpret_cast<sockaddr*>(&address),
        sizeof(address)
    ) == SOCKET_ERROR) {
        std::cerr << "Bind failed: " << WSAGetLastError() << "\n";
        closesocket(listenSocket);
        WSACleanup();
        return 1;
    }

    if (listen(listenSocket, SOMAXCONN) == SOCKET_ERROR) {
        std::cerr << "Listen failed\n";
        closesocket(listenSocket);
        WSACleanup();
        return 1;
    }

    completionPort = CreateIoCompletionPort(
        INVALID_HANDLE_VALUE,
        nullptr,
        0,
        0
    );

    if (!completionPort) {
        std::cerr << "IOCP creation failed\n";
        closesocket(listenSocket);
        WSACleanup();
        return 1;
    }

    unsigned int threadCount =
        std::max(2u, std::thread::hardware_concurrency());

    std::vector<std::thread> workers;

    for (unsigned int i = 0; i < threadCount; ++i) {
        workers.emplace_back(worker);
        workers.back().detach();
    }

    std::cout << "C++ IOCP server listening on port "
              << PORT << "\n";

    while (true) {
        SOCKET client = accept(listenSocket, nullptr, nullptr);

        if (client == INVALID_SOCKET) {
            continue;
        }

        auto* connection = new Connection{};
        connection->socket = client;

        if (!CreateIoCompletionPort(
            reinterpret_cast<HANDLE>(client),
            completionPort,
            reinterpret_cast<ULONG_PTR>(connection),
            0
        )) {
            closeConnection(connection);
            continue;
        }

        if (!postRead(connection)) {
            closeConnection(connection);
        }
    }

    return 0;
}
