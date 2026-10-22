#pragma once
void royd_test_close(int);
namespace android::base {
class unique_fd {
    int mFd;
public:
    explicit unique_fd(int fd) : mFd(fd) {}
    ~unique_fd() { if (mFd >= 0) royd_test_close(mFd); }
    bool ok() const { return mFd >= 0; }
    int get() const { return mFd; }
    void reset(int fd) { if (mFd >= 0) royd_test_close(mFd); mFd = fd; }
};
}
