module.exports = {
  apps: [
    {
      name: "winr-keeper",
      cwd: __dirname,
      script: "npm",
      args: "run start:dist",
      exec_mode: "fork",
      instances: 1,
      autorestart: true,
      max_memory_restart: "1G",
      env: {
        NODE_ENV: "production",
      },
    },
  ],
};
