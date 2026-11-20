#include "photo_store.h"

#include <QColor>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QImageReader>
#include <QPainter>
#include <QTemporaryDir>

#include <array>
#include <barrier>
#include <cerrno>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <sys/inotify.h>
#include <sys/resource.h>
#include <thread>
#include <unistd.h>

namespace {

constexpr int width = 320;
constexpr int height = 240;
constexpr int burstSize = 8;

void require(bool condition, const char *message)
{
    if (!condition) {
        std::fprintf(stderr, "QCAM_PHOTO_FAIL %s\n", message);
        std::exit(EXIT_FAILURE);
    }
}

QStringList entries(const QString &directory)
{
    return QDir(directory).entryList(QDir::AllEntries | QDir::Hidden | QDir::System |
                                      QDir::NoDotAndDotDot, QDir::Name);
}

QByteArray readBytes(const QString &path)
{
    QFile file(path);
    require(file.open(QIODevice::ReadOnly), "open published photo");
    return file.readAll();
}

QImage chart(int index)
{
    QImage image(width, height, QImage::Format_RGB32);
    QPainter painter(&image);
    painter.fillRect(0, 0, width / 2, height / 2, QColor(224, 44, 56));
    painter.fillRect(width / 2, 0, width / 2, height / 2, QColor(44, 194, 84));
    painter.fillRect(0, height / 2, width / 2, height / 2, QColor(34, 80, 222));
    painter.fillRect(width / 2, height / 2, width / 2, height / 2,
                     QColor(20 + index * 11, 230 - index * 10, 245 - index * 10));
    return image;
}

void checkPhoto(const QString &path, const QString &directory, const QImage &expected)
{
    QFileInfo photo(path);
    require(photo.absolutePath() == QDir(directory).absolutePath(), "saved outside requested directory");
    require(photo.isFile() && !photo.isSymLink() && photo.suffix().compare("jpg", Qt::CaseInsensitive) == 0,
            "published result is a regular .jpg");
    QByteArray bytes = readBytes(path);
    require(bytes.startsWith(QByteArray::fromHex("ffd8ff")) && bytes.endsWith(QByteArray::fromHex("ffd9")),
            "published result has JPEG start and end markers");
    QImageReader reader(path);
    reader.setDecideFormatFromContent(true);
    require(reader.format() == "jpeg", "Qt identified JPEG content");
    QImage decoded = reader.read();
    require(decoded.size() == expected.size(), "decoded dimensions match captured frame");
    for (int y : {height / 4, height * 3 / 4}) {
        for (int x : {width / 4, width * 3 / 4}) {
            QColor pixel = decoded.pixelColor(x, y);
            QColor original = expected.pixelColor(x, y);
            require(std::abs(pixel.red() - original.red()) <= 12 &&
                        std::abs(pixel.green() - original.green()) <= 12 &&
                        std::abs(pixel.blue() - original.blue()) <= 12,
                    "decoded colour and orientation match captured frame");
        }
    }
}

QString savePhoto(const QImage &image, const QString &directory)
{
    QString path, error;
    const bool saved = qcam_photo::save(image, directory, &path, &error);
    if (!saved)
        std::fprintf(stderr, "%s\n", qPrintable(error));
    require(saved && !path.isEmpty() && error.isEmpty(), "save publishes a photo path and no error");
    checkPhoto(path, directory, image);
    return path;
}

void expectFailure(const QImage &image, const QString &directory)
{
    QString path, error;
    require(!qcam_photo::save(image, directory, &path, &error), "invalid save returns failure");
    require(path.isEmpty() && !error.isEmpty(), "failure reports an error and no published path");
}

void checkBurst(const QString &directory)
{
    QString original = savePhoto(chart(0), directory);
    QByteArray originalBytes = readBytes(original);
    for (int i = 1; i <= 4; ++i)
        savePhoto(chart(i), directory);

    struct Result {
        bool saved = false;
        QString path, error;
    };
    std::barrier ready(burstSize);
    std::array<Result, burstSize> results;
    std::array<std::thread, burstSize> workers;
    for (int i = 0; i < burstSize; ++i) {
        workers[i] = std::thread([&, i] {
            const QImage image = chart(i + 5);
            ready.arrive_and_wait();
            Result &result = results[i];
            result.saved = qcam_photo::save(image, directory, &result.path, &result.error);
        });
    }
    for (auto &worker : workers)
        worker.join();
    for (int i = 0; i < burstSize; ++i) {
        require(results[i].saved && !results[i].path.isEmpty() && results[i].error.isEmpty(),
                "concurrent save returned success and a path");
        checkPhoto(results[i].path, directory, chart(i + 5));
    }
    require(entries(directory).size() == 5 + burstSize, "each shot has a unique file and no intermediate remains");
    require(readBytes(original) == originalBytes, "saved photo was never overwritten");
    std::puts("QCAM_PHOTO_BURST sequential=5 concurrent=8 decoded=13 previous_preserved=yes");
}

void checkNoPublication(int watch)
{
    // Check the filesystem event stream as well as the final listing. A
    // broken implementation might briefly expose a partial .jpg then erase it.
    alignas(inotify_event) char events[4096];
    for (;;) {
        ssize_t size = read(watch, events, sizeof(events));
        if (size < 0 && errno == EINTR)
            continue;
        if (size < 0 && errno == EAGAIN)
            break;
        require(size > 0, "read destination filesystem events");
        for (ssize_t offset = 0; offset < size;) {
            const auto *event = reinterpret_cast<const inotify_event *>(events + offset);
            require(!(event->mask & IN_Q_OVERFLOW), "filesystem event stream did not overflow");
            require(!event->len || !QByteArray(event->name).endsWith(".jpg"),
                    "failed write never exposed a .jpg");
            offset += sizeof(*event) + event->len;
        }
    }
    require(close(watch) == 0, "close filesystem event observer");
}

void checkFailures(const QString &root, const QString &directory)
{
    const QImage image = chart(0);
    const QStringList before = entries(directory);
    expectFailure(QImage(), directory);
    expectFailure(image, QString());

    QString blocked = root + "/blocked";
    QFile obstacle(blocked);
    require(obstacle.open(QIODevice::WriteOnly) && obstacle.write("fixture") == 7,
            "create non-directory obstacle");
    obstacle.close();
    expectFailure(image, blocked);
    require(readBytes(blocked) == "fixture", "failed save leaves non-directory obstacle unchanged");

    const QByteArray priorBytes = readBytes(QDir(directory).filePath(before.first()));
    int watch = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    require(watch >= 0 &&
                inotify_add_watch(watch, QFile::encodeName(directory).constData(),
                                  IN_CREATE | IN_MOVED_TO) >= 0,
            "observe even temporary publication of final names");
    // A 512-byte cap is smaller than the JPEG data and forces a genuine short
    // write or EFBIG. All preceding assertions run without the cap.
    struct rlimit original;
    require(getrlimit(RLIMIT_FSIZE, &original) == 0, "read file size resource limit");
    require(original.rlim_cur > 512 && priorBytes.size() > 512,
            "fixture JPEG exceeds simulated write limit");
    struct rlimit limited = {512, original.rlim_max};
    auto handler = std::signal(SIGXFSZ, SIG_IGN);
    require(handler != SIG_ERR && setrlimit(RLIMIT_FSIZE, &limited) == 0, "enable bounded short-write test");
    QString failedPath, failure;
    const bool saved = qcam_photo::save(image, directory, &failedPath, &failure);
    require(setrlimit(RLIMIT_FSIZE, &original) == 0 && std::signal(SIGXFSZ, handler) != SIG_ERR,
            "restore surrounding fixture limits");
    require(!saved && failedPath.isEmpty() && !failure.isEmpty(), "partial write reports failure and no path");
    checkNoPublication(watch);
    require(entries(directory) == before, "failure leaves the directory and hidden entries unchanged");
    require(readBytes(QDir(directory).filePath(before.first())) == priorBytes, "failure preserves existing photo");
    savePhoto(image, directory);
    require(entries(directory).size() == before.size() + 1, "save recovers after I/O failure");
    std::puts("QCAM_PHOTO_FAILURE null_image=pass empty_directory=pass blocked_path=pass short_write_limit=512 visible_partial=0 leak=0 recovered=yes");
}

} // namespace

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    require(QImageReader::supportedImageFormats().contains("jpeg"), "Qt JPEG codec is installed");
    QTemporaryDir scratch;
    require(scratch.isValid(), "create disposable output directory");
    const QString directory = scratch.filePath("Pictures/Camera");
    require(!QDir(directory).exists(), "nested photo directory begins absent");
    checkBurst(directory);
    checkFailures(scratch.path(), directory);
    std::puts("Y700_QCAM_PHOTO_STORE_PASS");
    return EXIT_SUCCESS;
}
