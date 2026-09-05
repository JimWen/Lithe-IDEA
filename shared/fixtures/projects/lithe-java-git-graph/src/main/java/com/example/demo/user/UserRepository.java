package com.example.demo.user;


import java.util.List;

public class UserRepository {
    public List<UserSummary> findAll() {
        return List.of(
                new UserSummary(1L, "Ada Lovelace"),
                new UserSummary(2L, "Grace Hopper")
        );
    }

    public record UserSummary(Long id, String name) {}
}
