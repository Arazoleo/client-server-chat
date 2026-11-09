
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define BUFFER_SIZE 1024
#define MAX_CLIENTS 100
#define BENCH_BUF_SIZE (256 * 1024)

typedef struct Client {
    int fd;
    char name[32];
    struct Client *next;
} Client;

Client *clients = NULL;
int num_clients = 0;

pthread_mutex_t clients_mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t bench_mutex = PTHREAD_MUTEX_INITIALIZER;

int bench_active = 0;  
int bench_peak = 0;
unsigned long long bench_bytes = 0;
int bench_has_data = 0;
struct timespec bench_first;
struct timespec bench_last;


int ts_before(struct timespec *a, struct timespec *b) {
    return a->tv_sec < b->tv_sec ||
          (a->tv_sec == b->tv_sec && a->tv_nsec < b->tv_nsec);
}


/* Envia todos os bytes, mesmo se send() enviar parcialmente. */
int send_all(int fd, const char *data, size_t len) {
    size_t sent = 0;

    while (sent < len) {
        ssize_t n = send(fd, data + sent, len - sent,
                         MSG_NOSIGNAL);

        if (n == -1) {
            if (errno == EINTR)
                continue;
            return -1;
        }

        if (n == 0)
            return -1;

        sent += (size_t)n;
    }

    return 0;
}

/* Le uma linha terminada por '\n'. */
ssize_t read_line(int fd, char *buffer, size_t capacity) {
    size_t pos = 0;

    while (pos < capacity - 1) {
        char c;
        ssize_t n = recv(fd, &c, 1, 0);

        if (n == 0)
            return pos == 0 ? 0 : (ssize_t)pos;

        if (n == -1) {
            if (errno == EINTR)
                continue;
            return -1;
        }

        if (c == '\n')
            break;

        if (c != '\r')
            buffer[pos++] = c;
    }

    buffer[pos] = '\0';
    return (ssize_t)pos;
}

/* Distribui uma mensagem aos demais clientes. */
void broadcast(const char *message, Client *sender) {
    pthread_mutex_lock(&clients_mutex);

    Client *current = clients;

    while (current != NULL) {
        if (current != sender) {
            if (send_all(current->fd, message,
                         strlen(message)) == -1) {
                fprintf(stderr,
                        "Falha ao enviar para %s.\n",
                        current->name);
            }
        }

        current = current->next;
    }

    pthread_mutex_unlock(&clients_mutex);
}

double ts_diff(const struct timespec *a, const struct timespec *b) {
    return (double)(b->tv_sec - a->tv_sec)
         + (double)(b->tv_nsec - a->tv_nsec) / 1e9;
}

void bench_loop(int fd) {
    char *buf = malloc(BENCH_BUF_SIZE);
    unsigned long long total = 0;
    struct timespec first, last;
    int got = 0;

    if (buf == NULL) {
        perror("malloc");
        return;
    }

    pthread_mutex_lock(&bench_mutex);
    bench_active++;
    if (bench_active > bench_peak)
        bench_peak = bench_active;
    pthread_mutex_unlock(&bench_mutex);

    while(1){
        ssize_t n = recv(fd, buf, BENCH_BUF_SIZE, 0);

        if (n > 0) {
            clock_gettime(CLOCK_MONOTONIC, &last);
            if (!got) {                              /* NOVO */
                first = last;
                got = 1;
            }
            total += (unsigned long long)n;   /* conta o que realmente chegou */
        } else if (n == 0) {
            break;                            /* cliente fechou, ou seja, fim do fluxo */
        } else if (errno == EINTR) {
            continue;                         /* interrompido por sinal, tem que tentar de novo */
        } else {
            perror("recv");                   /* erro de verdade */
            break;
        }

    }

    free(buf);

    pthread_mutex_lock(&bench_mutex);

    bench_bytes += total;
    if (got) {
        if (!bench_has_data || ts_before(&first, &bench_first))
            bench_first = first;     /* guarda o mais cedo */
        if (!bench_has_data || ts_before(&bench_last, &last))
            bench_last = last;       /* guarda o mais tarde */
        bench_has_data = 1;
    }

    printf("BENCH_CLIENT bytes=%llu seconds=%.3f\n", total, got ? ts_diff(&first, &last) : 0.0);

    if (--bench_active == 0) {
        double secs = bench_has_data ? ts_diff(&bench_first, &bench_last) : 0.0;
        double mbps = secs > 0 ? (double)bench_bytes * 8.0 / secs / 1e6 : 0.0;

        printf("BENCH clients=%d bytes=%llu seconds=%.3f mbps=%.2f\n", bench_peak, bench_bytes, secs, mbps);

        bench_peak = 0;
        bench_bytes = 0;
        bench_has_data = 0;
    }
    fflush(stdout);
    pthread_mutex_unlock(&bench_mutex);
}


void *handle_client(void *arg) {
    Client *client = arg;
    char buffer[BUFFER_SIZE];
    char message[BUFFER_SIZE + 64];
    int registered = 0;

    /* A primeira linha recebida e o nome do usuario. */
    ssize_t n = read_line(client->fd, buffer, sizeof(buffer));

    if (n <= 0 || buffer[0] == '\0') {
        close(client->fd);
        free(client);
        return NULL;
    }

    if(strcmp(buffer, "/bench") == 0) {
        bench_loop(client->fd);
        close(client->fd);
        free(client);
        return NULL;
    }

    snprintf(client->name, sizeof(client->name),
             "%s", buffer);

    pthread_mutex_lock(&clients_mutex);

    if (num_clients >= MAX_CLIENTS) {
        pthread_mutex_unlock(&clients_mutex);

        const char *error = "Servidor cheio.\n";
        send_all(client->fd, error, strlen(error));
        close(client->fd);
        free(client);
        return NULL;
    }

    client->next = clients;
    clients = client;
    num_clients++;
    registered = 1;

    pthread_mutex_unlock(&clients_mutex);

    snprintf(message, sizeof(message),
             "*** %s entrou no chat. ***\n",
             client->name);
    broadcast(message, client);

    printf("Usuario conectado: %s\n", client->name);

    while ((n = read_line(client->fd, buffer,
                          sizeof(buffer))) > 0) {
        if (strcmp(buffer, "/quit") == 0)
            break;

        snprintf(message, sizeof(message),
                 "%s: %s\n", client->name, buffer);

        broadcast(message, client);
    }

    if (n == -1)
        perror("recv");

    if (registered) {
        pthread_mutex_lock(&clients_mutex);

        Client **current = &clients;

        while (*current != NULL && *current != client)
            current = &(*current)->next;

        if (*current == client) {
            *current = client->next;
            num_clients--;
        }

        pthread_mutex_unlock(&clients_mutex);

        snprintf(message, sizeof(message),
                 "*** %s saiu do chat. ***\n",
                 client->name);
        broadcast(message, NULL);
    }

    printf("Usuario desconectado: %s\n", client->name);

    close(client->fd);
    free(client);

    return NULL;
}

int main(int argc, char *argv[]) {
    int server_fd;
    struct sockaddr_in server_addr;

    if (argc != 2) {
        fprintf(stderr, "Uso: %s <porta>\n", argv[0]);
        return EXIT_FAILURE;
    }

    int port = atoi(argv[1]);

    signal(SIGPIPE, SIG_IGN);

    server_fd = socket(AF_INET, SOCK_STREAM, 0);

    if (server_fd == -1) {
        perror("socket");
        return EXIT_FAILURE;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR,
               &opt, sizeof(opt));

    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    server_addr.sin_port = htons(port);

    if (bind(server_fd, (struct sockaddr *)&server_addr,
             sizeof(server_addr)) == -1) {
        perror("bind");
        close(server_fd);
        return EXIT_FAILURE;
    }

    if (listen(server_fd, 128) == -1) {
        perror("listen");
        close(server_fd);
        return EXIT_FAILURE;
    }

    printf("Chat TCP ativo na porta %d.\n", port);

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t addr_len = sizeof(client_addr);

        int client_fd = accept(
            server_fd,
            (struct sockaddr *)&client_addr,
            &addr_len
        );

        if (client_fd == -1) {
            if (errno == EINTR)
                continue;

            perror("accept");
            continue;
        }

        Client *client = malloc(sizeof(Client));

        if (client == NULL) {
            perror("malloc");
            close(client_fd);
            continue;
        }

        client->fd = client_fd;
        client->name[0] = '\0';
        client->next = NULL;

        pthread_t tid;

        if (pthread_create(&tid, NULL,
                           handle_client, client) != 0) {
            fprintf(stderr, "Erro ao criar thread.\n");
            close(client_fd);
            free(client);
            continue;
        }

        pthread_detach(tid);
    }

    close(server_fd);
    pthread_mutex_destroy(&clients_mutex);

    return EXIT_SUCCESS;
}
