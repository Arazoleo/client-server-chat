
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/in.h>

#define BUFFER_SIZE 1024
#define MAX_BLOCK_SIZE (64 * 1024 * 1024)
/* Limite para duracoes e horarios: recusa inf e valores absurdos. */
#define MAX_SECONDS 1e12
/* Atraso maximo ao acordar para a largada, em segundos. */
#define MAX_START_DELAY 0.1

int sockfd;
pthread_mutex_t output_mutex = PTHREAD_MUTEX_INITIALIZER;

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

void *receive_messages(void *arg) {
    char buffer[BUFFER_SIZE];
    size_t pos = 0;

    (void)arg;

    while (1) {
        char c;
        ssize_t n = recv(sockfd, &c, 1, 0);

        if (n == 0) {
            pthread_mutex_lock(&output_mutex);
            printf("\nConexao encerrada pelo servidor.\n");
            fflush(stdout);
            pthread_mutex_unlock(&output_mutex);
            break;
        }

        if (n == -1) {
            if (errno == EINTR)
                continue;

            pthread_mutex_lock(&output_mutex);
            perror("recv");
            pthread_mutex_unlock(&output_mutex);
            break;
        }

        if (c == '\n') {
            buffer[pos] = '\0';

            pthread_mutex_lock(&output_mutex);
            printf("\r%s\n", buffer);
            fflush(stdout);
            pthread_mutex_unlock(&output_mutex);

            pos = 0;
        } else if (c != '\r') {
            if (pos < sizeof(buffer) - 1)
                buffer[pos++] = c;
        }
    }

    return NULL;
}

/* Abre a conexao em sockfd. Retorna 0 em caso de sucesso. */
int connect_to_server(const char *ip, int port) {
    struct sockaddr_in server_addr;

    sockfd = socket(AF_INET, SOCK_STREAM, 0);

    if (sockfd == -1) {
        perror("socket");
        return -1;
    }

    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(port);

    if (inet_pton(AF_INET, ip, &server_addr.sin_addr) != 1) {
        fprintf(stderr, "Endereco IPv4 invalido.\n");
        close(sockfd);
        return -1;
    }

    if (connect(sockfd, (struct sockaddr *)&server_addr,
                sizeof(server_addr)) == -1) {
        perror("connect");
        close(sockfd);
        return -1;
    }

    return 0;
}

typedef struct {
    double seconds;
    size_t block_size;
    int has_start_at;
    double start_at;   /* epoch em segundos, so vale com has_start_at */
} BenchConfig;

double clock_seconds(clockid_t clock) {
    struct timespec ts;

    clock_gettime(clock, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* Dorme ate o horario de largada. Retorna -1 se a largada ja passou,
 * ou se o cliente acordou atrasado demais para a rodada ser comparavel. */
int wait_for_start(double start_at) {
    double remaining = start_at - clock_seconds(CLOCK_REALTIME);

    if (remaining <= 0) {
        fprintf(stderr, "Horario de largada ja passou (%.3f s).\n", -remaining);
        return -1;
    }

    while (remaining > 0) {
        struct timespec ts;

        ts.tv_sec = (time_t)remaining;
        ts.tv_nsec = (long)((remaining - (double)ts.tv_sec) * 1e9);
        nanosleep(&ts, NULL);

        remaining = start_at - clock_seconds(CLOCK_REALTIME);
    }

    if (-remaining > MAX_START_DELAY) {
        fprintf(stderr, "Cliente acordou %.3f s depois da largada.\n", -remaining);
        return -1;
    }

    return 0;
}

/* Le uma duracao ou um horario em segundos. Retorna -1 se for invalido. */
int parse_seconds(const char *text, double *value) {
    char *end;

    errno = 0;
    *value = strtod(text, &end);

    if (end == text || *end != '\0' || errno != 0 ||
        !(*value > 0) || *value > MAX_SECONDS)
        return -1;

    return 0;
}

/* Le o tamanho do bloco em bytes. Retorna -1 se for invalido. */
int parse_block_size(const char *text, size_t *value) {
    char *end;

    if (text[0] < '0' || text[0] > '9')
        return -1;

    errno = 0;
    unsigned long parsed = strtoul(text, &end, 10);

    if (*end != '\0' || errno != 0 || parsed == 0 || parsed > MAX_BLOCK_SIZE)
        return -1;

    *value = (size_t)parsed;
    return 0;
}

/* Le "--bench <segundos> <bloco> [--start-at <epoch>]" a partir de argv[3]. */
int parse_bench_args(int argc, char *argv[], BenchConfig *config) {
    if ((argc != 6 && argc != 8) || strcmp(argv[3], "--bench") != 0)
        return -1;

    if (parse_seconds(argv[4], &config->seconds) == -1 ||
        parse_block_size(argv[5], &config->block_size) == -1)
        return -1;

    config->has_start_at = argc == 8;

    if (config->has_start_at &&
        (strcmp(argv[6], "--start-at") != 0 ||
         parse_seconds(argv[7], &config->start_at) == -1))
        return -1;

    return 0;
}

/* Espera a largada e envia blocos ate o tempo acabar. */
int send_blocks(const BenchConfig *config, const char *block,
                unsigned long long *total, double *elapsed) {
    if (config->has_start_at && wait_for_start(config->start_at) == -1)
        return -1;

    double start = clock_seconds(CLOCK_MONOTONIC);
    double deadline = start + config->seconds;

    *total = 0;

    while (clock_seconds(CLOCK_MONOTONIC) < deadline) {
        if (send_all(sockfd, block, config->block_size) == -1) {
            perror("send");
            return -1;
        }

        *total += config->block_size;
    }

    *elapsed = clock_seconds(CLOCK_MONOTONIC) - start;
    return 0;
}

/* Manda /bench, envia os blocos e encerra o fluxo com shutdown(). */
int run_bench(const BenchConfig *config) {
    if (send_all(sockfd, "/bench\n", 7) == -1) {
        perror("send");
        return -1;
    }

    char *block = malloc(config->block_size);

    if (block == NULL) {
        perror("malloc");
        return -1;
    }

    memset(block, 'x', config->block_size);

    unsigned long long total;
    double elapsed;
    int status = send_blocks(config, block, &total, &elapsed);

    free(block);

    if (status == -1)
        return -1;

    if (shutdown(sockfd, SHUT_WR) == -1) {
        perror("shutdown");
        return -1;
    }

    /* O servidor so fecha depois de contabilizar tudo o que recebeu. */
    char drain[64];

    while (1) {
        ssize_t n = recv(sockfd, drain, sizeof(drain), 0);

        if (n == 0) {
            printf("BENCH_SENT bytes=%llu seconds=%.3f\n", total, elapsed);
            return 0;
        }

        if (n == -1 && errno != EINTR) {
            perror("recv");
            return -1;
        }
    }
}

int main(int argc, char *argv[]) {
    char name[32];
    char buffer[BUFFER_SIZE];
    pthread_t receiver;

    BenchConfig config;
    int bench = argc > 3 && parse_bench_args(argc, argv, &config) == 0;

    if (argc != 3 && !bench) {
        fprintf(stderr, "Uso: %s <IP> <porta>\n", argv[0]);
        fprintf(stderr, "     %s <IP> <porta> --bench <segundos> <bloco_em_bytes>"
                        " [--start-at <epoch>]\n", argv[0]);
        return EXIT_FAILURE;
    }

    int port = atoi(argv[2]);

    signal(SIGPIPE, SIG_IGN);

    if (connect_to_server(argv[1], port) == -1)
        return EXIT_FAILURE;

    if (bench) {
        int status = run_bench(&config);

        close(sockfd);
        return status == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }

    printf("Seu nome: ");

    if (fgets(name, sizeof(name), stdin) == NULL) {
        close(sockfd);
        return EXIT_FAILURE;
    }

    name[strcspn(name, "\r\n")] = '\0';

    if (name[0] == '\0' ||
        strchr(name, '\n') != NULL) {
        fprintf(stderr, "Nome invalido.\n");
        close(sockfd);
        return EXIT_FAILURE;
    }

    if (send_all(sockfd, name, strlen(name)) == -1 ||
        send_all(sockfd, "\n", 1) == -1) {
        perror("send");
        close(sockfd);
        return EXIT_FAILURE;
    }

    if (pthread_create(&receiver, NULL,
                       receive_messages, NULL) != 0) {
        fprintf(stderr, "Erro ao criar thread receptora.\n");
        close(sockfd);
        return EXIT_FAILURE;
    }

    printf("Conectado! Digite /quit para sair.\n");

    while (1) {
        pthread_mutex_lock(&output_mutex);
        printf("> ");
        fflush(stdout);
        pthread_mutex_unlock(&output_mutex);

        if (fgets(buffer, sizeof(buffer), stdin) == NULL)
            break;

        if (strcmp(buffer, "/quit\n") == 0 ||
            strcmp(buffer, "/quit") == 0) {
            send_all(sockfd, "/quit\n", 6);
            break;
        }

        size_t len = strlen(buffer);

        if (len > 0 && buffer[len - 1] != '\n') {
            int c;
            while ((c = getchar()) != '\n' && c != EOF)
                ;
            fprintf(stderr, "Mensagem muito longa.\n");
            continue;
        }

        if (send_all(sockfd, buffer, len) == -1) {
            perror("send");
            break;
        }
    }

    shutdown(sockfd, SHUT_RDWR);
    pthread_join(receiver, NULL);
    close(sockfd);

    pthread_mutex_destroy(&output_mutex);

    printf("Cliente encerrado.\n");

    return EXIT_SUCCESS;
}
